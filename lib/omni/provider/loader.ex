defmodule Omni.Provider.Loader do
  # Assembles providers and their models, and writes them to the store.
  #
  # For each provider id:
  #
  #   1. Resolve the provider module: config `module:`, else the built-in.
  #   2. Fetch catalog data from the source: a partial %Provider{} with its
  #      endpoints, and provider-less models. An unknown id starts empty.
  #   3. Merge the provider: source <- module config/0, then move those
  #      endpoint URLs to app config's `host:`, then <- app config. Endpoints
  #      merge by dialect module, then by field.
  #   4. Merge config `models:` entries over source models by id; entries
  #      with new ids are added. Pass the models through the module's
  #      models/2.
  #   5. Validate the provider (raise), then check each model has a dialect
  #      the provider has an endpoint for: catalog models without are skipped
  #      with a warning, config models without raise. Nothing is filled in.
  #   6. Stamp the provider onto every model, apply the global filter.
  #
  # assemble/2 does all of that without touching the store; load/1 stores.
  @moduledoc false

  require Logger

  alias Omni.{Model, Provider, Source}
  alias Omni.Provider.{Builtins, Endpoint}

  @config_keys [
    :name,
    :host,
    :api_key,
    :auth,
    :headers,
    :dialects,
    :module,
    :models,
    :source
  ]
  @module_config_keys [:name, :api_key, :auth, :headers, :dialects]
  @endpoint_keys [:base_url, :compat]
  @models_keys [:providers, :source, :filter]

  @default_source Omni.Sources.ModelsDev

  # -- Boot -------------------------------------------------------------------

  @doc """
  Validates app config and loads the selected providers. Called at startup.
  """
  @spec boot() :: :ok
  def boot do
    validate_env!()

    models_config()
    |> Map.get(:providers, :builtins)
    |> expand_providers!()
    |> load()
  end

  # -- Loading ----------------------------------------------------------------

  @doc """
  Assembles and stores providers. Entries are ids or `{id, opts}`.
  """
  @spec load([atom() | {atom(), keyword() | map()}]) :: :ok
  def load(entries) when is_list(entries) do
    # The cache scope lets sources share expensive work (like decoding a
    # catalog snapshot) across the pass and release it when the pass ends.
    Source.with_cache(fn ->
      for entry <- entries do
        {id, opts} = normalize_entry!(entry)
        store(assemble(id, opts))
      end
    end)

    :ok
  end

  @doc """
  Assembles a provider and its final models without storing them.
  """
  @spec assemble(atom(), keyword() | map()) :: {Provider.t(), [Model.t()]}
  def assemble(id, opts \\ []) when is_atom(id) do
    config = merge_config(app_config(id), normalize_config!(id, opts, @config_keys))
    module = resolve_module!(id, config)
    {source, source_opts} = resolve_source!(config)
    {source_provider, source_models} = fetch(source, id, source_opts)

    # host: moves the URLs the source and module supply; URLs written in app
    # config are used as written, so they merge after it.
    provider =
      source_provider
      |> merge_provider(module_config(id, module))
      |> put_host!(Map.get(config, :host))

    check_legacy_base_url!(id, config, provider)

    provider =
      provider
      |> merge_provider(Map.drop(config, [:host, :models, :source, :module]))
      |> Map.put(:module, module)
      |> fill_defaults()

    validate_provider!(provider)

    {models, config_ids} = merge_models(id, source_models, Map.get(config, :models, []))

    models =
      if Provider.callback?(module, :models, 2),
        do: module.models(models, provider),
        else: models

    models =
      provider
      |> check_models!(models, config_ids)
      |> Enum.map(&%{&1 | provider: provider})
      |> apply_filter()
      |> Enum.sort_by(& &1.id)

    if models == [] and provider.dialects == %{},
      do: Logger.warning("Omni: provider #{inspect(id)} loaded no models")

    {provider, models}
  end

  @doc """
  Registers one model under its (loaded) provider.
  """
  @spec put_model(Model.t()) :: :ok
  def put_model(%Model{provider: %Provider{id: id}} = model) do
    if model.dialects == %{} do
      raise ArgumentError,
            "cannot register model #{inspect(model.id)}: it has no dialects — set one, " <>
              "e.g. dialects: %{text: Omni.Dialects.OpenAICompletions}"
    end

    with_lock(fn ->
      unless Map.has_key?(:persistent_term.get(Provider.providers_key(), %{}), id) do
        raise ArgumentError,
              "cannot register model #{inspect(model.id)}: provider #{inspect(id)} is not loaded"
      end

      models = :persistent_term.get(Provider.models_key(id), %{})
      :persistent_term.put(Provider.models_key(id), Map.put(models, model.id, model))
    end)

    :ok
  end

  # Writing a changed value to persistent term scans every process heap, so
  # loading is a boot or on-demand operation, never per request. The lock
  # keeps concurrent loads from dropping each other's entries.
  defp store({%Provider{id: id} = provider, models}) do
    with_lock(fn ->
      :persistent_term.put(Provider.models_key(id), Map.new(models, &{&1.id, &1}))
      providers = :persistent_term.get(Provider.providers_key(), %{})
      :persistent_term.put(Provider.providers_key(), Map.put(providers, id, provider))
    end)
  end

  defp with_lock(fun), do: :global.trans({__MODULE__, :store}, fun, [node()])

  # -- Sources ----------------------------------------------------------------

  defp resolve_source!(config) do
    source = Map.get(config, :source) || models_config()[:source] || @default_source
    normalize_source!(source)
  end

  defp normalize_source!({module, opts}) when is_atom(module) and is_list(opts) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2) do
      raise ArgumentError,
            "#{inspect(module)} is not an Omni.Source — it does not export fetch/2"
    end

    {module, opts}
  end

  defp normalize_source!(module) when is_atom(module), do: normalize_source!({module, []})

  defp normalize_source!(other) do
    raise ArgumentError,
          "invalid model source #{inspect(other)} — expected a module or a {module, opts} tuple"
  end

  defp fetch(source, id, opts) do
    case source.fetch(id, opts) do
      {:ok, %Provider{} = provider, models} when is_list(models) ->
        dialects = normalize_dialects!(id, provider.dialects)
        {merge_provider(%{provider | id: id, dialects: %{}}, %{dialects: dialects}), models}

      {:error, :unknown_provider} ->
        {%Provider{id: id}, []}

      {:error, reason} ->
        Logger.warning(
          "Omni: failed to fetch provider #{inspect(id)} from #{inspect(source)} " <>
            "(#{inspect(reason)}) — loading it from config alone"
        )

        {%Provider{id: id}, []}
    end
  end

  # -- Merging ----------------------------------------------------------------

  # Merges app config with load/1 opts. Values replace; headers merge by key,
  # dialects by module and then by field (base_url replaces, compat merges by
  # flag). Model entries stack, merged by id in merge_models/3.
  defp merge_config(a, b) do
    Map.merge(a, b, fn
      :headers, x, y -> Map.merge(x, y)
      :dialects, x, y -> Map.merge(x, y, fn _dialect, e1, e2 -> merge_endpoint(e1, e2) end)
      :models, x, y -> x ++ y
      _key, _x, y -> y
    end)
  end

  defp merge_endpoint(a, b) do
    Map.merge(a, b, fn
      :compat, x, y -> Map.merge(x, y)
      _key, _x, y -> y
    end)
  end

  defp merge_provider(%Provider{} = provider, config) do
    Enum.reduce(config, provider, fn
      {:headers, headers}, acc -> %{acc | headers: Map.merge(acc.headers, headers)}
      {:dialects, dialects}, acc -> %{acc | dialects: merge_endpoints(acc.dialects, dialects)}
      {:legacy_base_url, _}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # Applies a layer's endpoint changes to the provider's endpoints.
  defp merge_endpoints(endpoints, changes) do
    Enum.reduce(changes, endpoints, fn {dialect, change}, acc ->
      endpoint = Map.get(acc, dialect, %Endpoint{})

      endpoint = %Endpoint{
        base_url: Map.get(change, :base_url, endpoint.base_url),
        compat: Map.merge(endpoint.compat, Map.get(change, :compat, %{}))
      }

      Map.put(acc, dialect, endpoint)
    end)
  end

  defp put_host!(provider, nil), do: provider

  defp put_host!(%Provider{id: id} = provider, host) do
    case Endpoint.validate_host(host) do
      :ok ->
        dialects =
          Map.new(provider.dialects, fn {dialect, endpoint} ->
            {dialect, %{endpoint | base_url: Endpoint.put_host(endpoint.base_url, host)}}
          end)

        %{provider | dialects: dialects}

      {:error, _} ->
        raise ArgumentError,
              "provider #{inspect(id)}: host: takes an origin such as \"http://gpu-box:11434\" " <>
                "(scheme, host and port, no path), got #{inspect(host)}. To change a path, " <>
                "set the endpoint's URL: dialects: %{Module => [base_url: \"...\"]}"
    end
  end

  # Config entries merge over source models with the same id, field by field
  # (dialects by capability); entries with new ids are added. Returns the
  # models and the ids config named.
  defp merge_models(id, source_models, entries) do
    models = Map.new(source_models, &{&1.id, &1})

    {models, config_ids} =
      Enum.reduce(entries, {models, MapSet.new()}, fn entry, {models, config_ids} ->
        model =
          case Map.fetch(models, entry.id) do
            {:ok, existing} -> config_model(id, merge_attrs(existing, entry))
            :error -> config_model(id, Map.put_new(entry, :name, entry.id))
          end

        {Map.put(models, model.id, model), MapSet.put(config_ids, model.id)}
      end)

    {Map.values(models), config_ids}
  end

  defp merge_attrs(%Model{} = model, entry) do
    attrs = Map.from_struct(model)

    Map.merge(attrs, entry, fn
      :dialects, x, y -> Map.merge(x, Map.new(y))
      _key, _x, y -> y
    end)
  end

  defp config_model(id, attrs) do
    Model.new(attrs)
  rescue
    e in [KeyError, ArgumentError] ->
      raise ArgumentError,
            "invalid model #{inspect(attrs.id)} for provider #{inspect(id)} in " <>
              "config :omni, :providers — #{Exception.message(e)}"
  end

  # -- Model checks -----------------------------------------------------------

  # A model needs at least one dialect, and an endpoint for each. Catalog
  # models that fall short are skipped with a warning (a gap in the data);
  # config models raise (a mistake in config). Dialects are never filled in.
  defp check_models!(%Provider{id: id} = provider, models, config_ids) do
    {models, no_dialect, no_endpoint} =
      Enum.reduce(models, {[], [], []}, fn model, {models, no_dialect, no_endpoint} ->
        cond do
          model.dialects == %{} ->
            {models, [model | no_dialect], no_endpoint}

          Enum.all?(model.dialects, fn {_cap, dialect} -> served?(provider, dialect) end) ->
            {[model | models], no_dialect, no_endpoint}

          true ->
            {models, no_dialect, [model | no_endpoint]}
        end
      end)

    {config_no_dialect, no_dialect} = Enum.split_with(no_dialect, &(&1.id in config_ids))
    {config_no_endpoint, no_endpoint} = Enum.split_with(no_endpoint, &(&1.id in config_ids))

    with [model | _] <- Enum.reverse(config_no_dialect) do
      raise ArgumentError,
            "provider #{inspect(id)}: model #{inspect(model.id)} in config :omni, :providers " <>
              "has no dialect — name it: models: [[id: #{inspect(model.id)}, " <>
              "dialects: %{text: Omni.Dialects.OpenAICompletions}]]"
    end

    with [model | _] <- Enum.reverse(config_no_endpoint) do
      raise ArgumentError,
            "provider #{inspect(id)}: model #{inspect(model.id)} in config :omni, :providers " <>
              "speaks #{inspect(Map.values(model.dialects))}, which the provider has no " <>
              "endpoint for — add one: dialects: %{Module => [base_url: \"https://...\"]}"
    end

    warn_skipped(id, Enum.reverse(no_dialect), "no dialect", fn _model -> "" end)

    warn_skipped(id, Enum.reverse(no_endpoint), "a dialect it has no endpoint for", fn model ->
      " (#{inspect(Map.values(model.dialects))})"
    end)

    Enum.reverse(models)
  end

  defp served?(%Provider{dialects: dialects}, dialect), do: Map.has_key?(dialects, dialect)

  defp warn_skipped(_id, [], _why, _detail), do: :ok

  defp warn_skipped(id, skipped, why, detail) do
    Logger.warning(
      "Omni: provider #{inspect(id)}: skipped #{length(skipped)} models with #{why}: " <>
        Enum.map_join(skipped, ", ", &"#{&1.id}#{detail.(&1)}")
    )
  end

  # -- Defaults and validation ------------------------------------------------

  defp fill_defaults(%Provider{id: id} = provider) do
    %{provider | auth: provider.auth || :dialect, name: provider.name || to_string(id)}
  end

  defp validate_provider!(%Provider{id: id} = provider) do
    for {dialect, endpoint} <- provider.dialects do
      validate_dialect!(id, dialect)
      validate_compat!(id, dialect, endpoint.compat)
    end

    validate_auth!(id, provider.auth)
  end

  defp validate_dialect!(id, dialect) do
    unless is_atom(dialect) and Omni.Dialect.capability(dialect) != nil and
             function_exported?(dialect, :handle_body, 3) and
             function_exported?(dialect, :auth, 0) and
             function_exported?(dialect, :compat_schema, 0) do
      raise ArgumentError,
            "provider #{inspect(id)}: #{inspect(dialect)} is not an Omni.Dialect module"
    end
  end

  defp validate_compat!(id, dialect, flags) do
    schema = dialect.compat_schema()

    case Map.keys(flags) -- Map.keys(schema) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "provider #{inspect(id)}: unknown compat flags #{inspect(unknown)} for " <>
                "#{inspect(dialect)} — expected any of #{inspect(Map.keys(schema))}"
    end

    case Peri.validate(schema, flags) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        raise ArgumentError,
              "provider #{inspect(id)}: invalid compat flags for #{inspect(dialect)} — " <>
                inspect(errors)
    end
  end

  defp validate_auth!(_id, auth) when auth in [:bearer, :none, :dialect], do: :ok
  defp validate_auth!(_id, {:header, name}) when is_binary(name), do: :ok

  defp validate_auth!(id, auth) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid auth #{inspect(auth)} — expected :bearer, " <>
            "{:header, name}, :none, or :dialect"
  end

  defp apply_filter(models) do
    case models_config()[:filter] do
      nil -> models
      {mod, fun} -> Enum.filter(models, &apply(mod, fun, [&1]))
      fun when is_function(fun, 1) -> Enum.filter(models, fun)
    end
  end

  # -- Module -----------------------------------------------------------------

  defp resolve_module!(id, config) do
    case Map.get(config, :module) || Builtins.module(id) do
      nil ->
        nil

      module when is_atom(module) ->
        unless Code.ensure_loaded?(module) do
          raise ArgumentError,
                "provider #{inspect(id)}: module #{inspect(module)} is not available"
        end

        module

      other ->
        raise ArgumentError, "provider #{inspect(id)}: invalid module #{inspect(other)}"
    end
  end

  defp module_config(id, module) do
    if Provider.callback?(module, :config, 0),
      do:
        normalize_config!(id, module.config(), @module_config_keys, "#{inspect(module)}.config/0"),
      else: %{}
  end

  # -- Config -----------------------------------------------------------------

  defp models_config do
    case Application.get_env(:omni, :models) do
      nil -> %{}
      config -> Map.new(config)
    end
  end

  defp app_config(id) do
    case Application.get_env(:omni, :providers, []) do
      configs when is_list(configs) or is_map(configs) ->
        case configs |> Map.new() |> Map.get(id) do
          nil -> %{}
          config -> normalize_config!(id, config, @config_keys)
        end

      _ ->
        %{}
    end
  end

  defp normalize_entry!(id) when is_atom(id), do: {id, %{}}

  defp normalize_entry!({id, opts}) when is_atom(id) and (is_list(opts) or is_map(opts)),
    do: {id, opts}

  defp normalize_entry!(other) do
    raise ArgumentError,
          "invalid provider entry #{inspect(other)} — expected an id or {id, opts}"
  end

  defp normalize_config!(id, config, allowed, where \\ "config :omni, :providers")

  defp normalize_config!(id, config, allowed, where) when is_list(config) or is_map(config) do
    unless is_map(config) or Keyword.keyword?(config) do
      raise ArgumentError,
            "invalid config for provider #{inspect(id)} in #{where}: expected a keyword list, " <>
              "got #{inspect(config)}"
    end

    Map.new(config, fn
      # A v1 provider-level base_url: assemble/2 raises once it knows the
      # provider's endpoints, so the message can say exactly what to write.
      {:base_url, url} when allowed == @config_keys ->
        {:legacy_base_url, url}

      {key, value} ->
        unless key in allowed do
          raise ArgumentError, unknown_key_message(id, key, allowed, where)
        end

        {key, normalize_value!(id, key, value)}
    end)
  end

  defp normalize_config!(id, config, _allowed, where) do
    raise ArgumentError,
          "invalid config for provider #{inspect(id)} in #{where}: expected a keyword list, " <>
            "got #{inspect(config)}"
  end

  defp unknown_key_message(id, :auth_header, _allowed, where) do
    "provider #{inspect(id)} in #{where}: auth_header: was replaced by auth: — " <>
      "use auth: {:header, \"x-api-key\"}"
  end

  defp unknown_key_message(id, :compat, _allowed, where) do
    "provider #{inspect(id)} in #{where}: compat: moved under its dialect — use " <>
      "dialects: %{Omni.Dialects.OpenAICompletions => [compat: [...]]}, with like: " <>
      "inside it to copy a built-in's flags"
  end

  defp unknown_key_message(id, :base_url, _allowed, where) do
    "provider #{inspect(id)} in #{where}: base_url: moved to each dialect's endpoint — use " <>
      "dialects: %{Omni.Dialects.OpenAICompletions => [base_url: \"https://...\"]}"
  end

  defp unknown_key_message(id, key, allowed, where) do
    "provider #{inspect(id)} in #{where}: unknown key #{inspect(key)} — " <>
      "expected one of #{inspect(allowed)}"
  end

  # Provider-level base_url is gone. Suggest host: when the URL only changes
  # the origin of the provider's one endpoint, else that endpoint's URL.
  defp check_legacy_base_url!(id, %{legacy_base_url: url}, %Provider{dialects: dialects}) do
    {origin, path} = Endpoint.split(url)

    suggestion =
      case Map.to_list(dialects) do
        [{_dialect, %Endpoint{base_url: current}}]
        when is_binary(current) and origin != "" ->
          {_, current_path} = Endpoint.split(current)

          if String.trim_trailing(current_path, "/") == String.trim_trailing(path, "/"),
            do: "#{id}: [host: #{inspect(origin)}]",
            else:
              "#{id}: [dialects: %{#{inspect(hd(Map.keys(dialects)))} => [base_url: #{inspect(url)}]}]"

        [{dialect, _endpoint}] ->
          "#{id}: [dialects: %{#{inspect(dialect)} => [base_url: #{inspect(url)}]}]"

        _ ->
          "#{id}: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: #{inspect(url)}]}]"
      end

    raise ArgumentError, """
    provider #{inspect(id)}: base_url: is no longer a provider key — each dialect \
    the provider serves has an endpoint with its own base_url, and host: moves \
    the origin of all of them. Use:

        config :omni, :providers,
          #{suggestion}
    """
  end

  defp check_legacy_base_url!(_id, _config, _provider), do: :ok

  defp normalize_value!(id, :dialects, dialects), do: normalize_dialects!(id, dialects)

  defp normalize_value!(id, :headers, headers) when is_list(headers) or is_map(headers) do
    Map.new(headers, fn
      {k, v} when is_binary(k) or is_atom(k) -> {to_string(k), v}
      other -> raise ArgumentError, "provider #{inspect(id)}: invalid header #{inspect(other)}"
    end)
  end

  defp normalize_value!(id, :models, models) when is_list(models) do
    Enum.map(models, fn
      model_id when is_binary(model_id) ->
        %{id: model_id}

      attrs when is_list(attrs) or is_map(attrs) ->
        attrs = Map.new(attrs)

        unless is_binary(attrs[:id]) do
          raise ArgumentError, "provider #{inspect(id)}: model entry #{inspect(attrs)} has no :id"
        end

        attrs

      other ->
        raise ArgumentError, "provider #{inspect(id)}: invalid model entry #{inspect(other)}"
    end)
  end

  defp normalize_value!(id, :host, host) when not is_binary(host) do
    raise ArgumentError, "provider #{inspect(id)}: invalid host #{inspect(host)}"
  end

  defp normalize_value!(id, key, value) when key in [:headers, :models] do
    raise ArgumentError, "provider #{inspect(id)}: invalid #{key} #{inspect(value)}"
  end

  defp normalize_value!(_id, _key, value), do: value

  # %{Module => [base_url: "...", compat: [...]]} (or keyword lists, or
  # %Endpoint{} from a source) → %{Module => %{base_url: ..., compat: %{}}},
  # holding only the fields the layer sets.
  defp normalize_dialects!(id, dialects) when is_list(dialects) or is_map(dialects) do
    Map.new(dialects, fn
      {dialect, endpoint} when is_atom(dialect) and not is_nil(dialect) ->
        unless module_atom?(dialect),
          do: raise(ArgumentError, legacy_dialects_message(id, dialects))

        {dialect, normalize_endpoint!(id, dialect, endpoint)}

      other ->
        raise ArgumentError, "provider #{inspect(id)}: invalid dialects entry #{inspect(other)}"
    end)
  end

  defp normalize_dialects!(id, other) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid dialects #{inspect(other)} — expected " <>
            "%{Module => [base_url: ..., compat: [...]]}"
  end

  defp normalize_endpoint!(_id, _dialect, %Endpoint{base_url: url, compat: compat}),
    do: %{base_url: url, compat: compat}

  defp normalize_endpoint!(id, dialect, endpoint) when is_list(endpoint) or is_map(endpoint) do
    unless is_map(endpoint) or Keyword.keyword?(endpoint) do
      raise ArgumentError,
            "provider #{inspect(id)}: invalid endpoint for #{inspect(dialect)} " <>
              "#{inspect(endpoint)} — expected [base_url: ..., compat: [...]]"
    end

    Map.new(endpoint, fn
      {:base_url, url} -> {:base_url, base_url!(id, dialect, url)}
      {:compat, compat} -> {:compat, compat!(id, dialect, compat)}
      {key, _} -> raise ArgumentError, unknown_endpoint_key_message(id, dialect, key)
    end)
  end

  defp normalize_endpoint!(id, dialect, other) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid endpoint for #{inspect(dialect)} #{inspect(other)} " <>
            "— expected [base_url: ..., compat: [...]]"
  end

  defp base_url!(_id, _dialect, url) when is_binary(url) or is_nil(url), do: url

  defp base_url!(id, dialect, url) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid base_url #{inspect(url)} for #{inspect(dialect)}"
  end

  # Flags, with `like:` copying a built-in's flags for the same dialect
  # underneath them.
  defp compat!(id, dialect, compat) when is_list(compat) or is_map(compat) do
    unless is_map(compat) or Keyword.keyword?(compat) do
      raise ArgumentError,
            "provider #{inspect(id)}: invalid compat for #{inspect(dialect)} #{inspect(compat)}"
    end

    {like, flags} = compat |> Map.new() |> Map.pop(:like)
    Map.merge(like_compat!(id, dialect, like), flags)
  end

  defp compat!(id, dialect, compat) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid compat for #{inspect(dialect)} #{inspect(compat)}"
  end

  defp like_compat!(_id, _dialect, nil), do: %{}

  defp like_compat!(id, dialect, target) when is_atom(target) do
    case Builtins.module(target) do
      nil ->
        raise ArgumentError,
              "provider #{inspect(id)}: compat like: #{inspect(target)} is not a built-in " <>
                "provider — expected one of #{inspect(Builtins.ids())}"

      module ->
        config =
          normalize_config!(
            target,
            module.config(),
            @module_config_keys,
            "#{inspect(module)}.config/0"
          )

        case config |> Map.get(:dialects, %{}) |> Map.fetch(dialect) do
          {:ok, endpoint} ->
            Map.get(endpoint, :compat, %{})

          :error ->
            raise ArgumentError,
                  "provider #{inspect(id)}: compat like: #{inspect(target)} — " <>
                    "#{inspect(target)} sets no endpoint for #{inspect(dialect)}"
        end
    end
  end

  defp like_compat!(id, _dialect, target) do
    raise ArgumentError, "provider #{inspect(id)}: invalid compat like: #{inspect(target)}"
  end

  defp unknown_endpoint_key_message(id, dialect, key) do
    "provider #{inspect(id)}: unknown key #{inspect(key)} for #{inspect(dialect)} — " <>
      "expected one of #{inspect(@endpoint_keys)}"
  end

  defp legacy_dialects_message(id, dialects) do
    """
    provider #{inspect(id)}: dialects: is now keyed by dialect module, each \
    with its endpoint (got #{inspect(dialects)}):

        config :omni, :providers,
          #{id}: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://..."]}]

    [] declares a dialect whose URL comes from the catalog or the provider \
    module. Compat flags go under the dialect too: [compat: [...]]. Models no \
    longer take a default dialect from the provider: a model the catalog \
    doesn't have names its own, models: [[id: "...", dialects: %{text: Module}]].
    """
  end

  # -- Boot validation --------------------------------------------------------

  defp validate_env! do
    for {key, _value} <- Application.get_all_env(:omni), module_atom?(key) do
      raise ArgumentError, module_config_message(key)
    end

    validate_models_config!(Application.get_env(:omni, :models))
    validate_providers_config!(Application.get_env(:omni, :providers))
  end

  defp validate_models_config!(nil), do: :ok

  defp validate_models_config!(config) when is_list(config) or is_map(config) do
    unless is_map(config) or Keyword.keyword?(config) do
      raise ArgumentError, "invalid config :omni, :models — expected a keyword list"
    end

    for {key, _} <- config, key not in @models_keys do
      raise ArgumentError,
            "config :omni, :models: unknown key #{inspect(key)} — expected one of " <>
              inspect(@models_keys)
    end

    case Map.new(config)[:filter] do
      nil -> :ok
      {mod, fun} when is_atom(mod) and is_atom(fun) -> :ok
      fun when is_function(fun, 1) -> :ok
      other -> raise ArgumentError, "config :omni, :models: invalid filter #{inspect(other)}"
    end
  end

  defp validate_models_config!(other) do
    raise ArgumentError,
          "invalid config :omni, :models #{inspect(other)} — expected a keyword list"
  end

  defp validate_providers_config!(nil), do: :ok

  defp validate_providers_config!(config) when is_map(config) do
    for {id, entry} <- config, do: normalize_config!(id, entry, @config_keys)
  end

  defp validate_providers_config!(config) when is_list(config) do
    unless Keyword.keyword?(config), do: raise(ArgumentError, legacy_providers_message(config))
    for {id, entry} <- config, do: normalize_config!(id, entry, @config_keys)
  end

  defp validate_providers_config!(config) do
    raise ArgumentError, legacy_providers_message(config)
  end

  defp expand_providers!(:builtins), do: Builtins.ids()

  defp expand_providers!(providers) when is_list(providers) do
    providers
    |> Enum.flat_map(fn
      :builtins ->
        Builtins.ids()

      id when is_atom(id) ->
        if module_atom?(id), do: raise(ArgumentError, module_in_list_message(id))
        [id]

      other ->
        raise ArgumentError,
              "invalid entry #{inspect(other)} in config :omni, :models, providers: — " <>
                "expected provider ids (e.g. :openai) or :builtins"
    end)
    |> Enum.uniq()
  end

  defp expand_providers!(other) do
    raise ArgumentError,
          "invalid providers: value #{inspect(other)} in config :omni, :models — " <>
            "expected :builtins or a list of provider ids"
  end

  defp module_atom?(atom),
    do: is_atom(atom) and String.starts_with?(Atom.to_string(atom), "Elixir.")

  defp id_hint(module), do: Builtins.id_for(module) || :my_provider

  defp module_config_message(module) do
    """
    config :omni, #{inspect(module)} is no longer read — provider config moved \
    under :providers, keyed by provider id:

        config :omni, :providers,
          #{id_hint(module)}: [api_key: {:system, "MY_KEY"}]

    Keys: #{inspect(@config_keys)}. Endpoint URLs are set per dialect, \
    version segment included: dialects: %{Module => [base_url: "https://api.openai.com/v1"]}.
    """
  end

  defp module_in_list_message(module) do
    """
    config :omni, :models, providers: takes provider ids, not modules \
    (got #{inspect(module)}). Use the id, e.g. :#{id_hint(module)}. To attach \
    a custom provider module, set module: in its :providers entry:

        config :omni, :models, providers: [:builtins, :#{id_hint(module)}]
        config :omni, :providers, #{id_hint(module)}: [module: #{inspect(module)}]
    """
  end

  defp legacy_providers_message(config) do
    """
    config :omni, :providers now configures providers by id; model loading \
    is selected under :models.

    Old:  config :omni, :providers, [:anthropic, :openai]

    New:  config :omni, :models,
            # :builtins (the default), or a list of provider ids
            providers: [:builtins, :togetherai]

          config :omni, :providers,
            togetherai: [host: "https://api.together.xyz"]

    Got: #{inspect(config)}
    """
  end
end
