defmodule Omni.Provider.Loader do
  # Assembles providers and their models, and writes them to the store.
  #
  # For each provider id:
  #
  #   1. Resolve the provider module: config `module:`, else the built-in.
  #   2. Fetch catalog data from the source: a partial %Provider{} and
  #      provider-less models. An id the catalog doesn't know starts empty.
  #   3. Merge the provider: source <- module config/0 <- app config.
  #      Config `models:` entries merge with source models by id.
  #   4. Pass models through the module's models/2.
  #   5. Fill dialect-less models from the provider; derive the provider's
  #      dialect list from its own plus its models'.
  #   6. Validate (raise on a broken provider, skip broken models), stamp
  #      the provider onto every model, apply the global filter.
  #
  # assemble/2 does all of that without touching the store; load/1 stores.
  @moduledoc false

  require Logger

  alias Omni.{Model, Provider, Source}
  alias Omni.Provider.Builtins

  @config_keys [:name, :base_url, :api_key, :auth, :headers, :dialects, :module, :models, :source]
  @module_config_keys [:name, :base_url, :api_key, :auth, :headers, :dialects]
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
    {source_provider, source_models, found?} = fetch(source, id, source_opts)

    provider =
      source_provider
      |> merge_provider(module_config(id, module))
      |> merge_provider(Map.drop(config, [:models, :source, :module]))
      |> Map.put(:module, module)

    models =
      source_models
      |> merge_models(config_models(id, Map.get(config, :models, [])))
      |> then(fn models ->
        if Provider.callback?(module, :models, 2),
          do: module.models(models, provider),
          else: models
      end)

    {provider, models} = resolve_dialects(provider, models)
    provider = fill_defaults(provider, found?)
    validate_provider!(provider, models, found?)

    {models, skipped} = Enum.split_with(models, &Map.has_key?(&1.dialects, :text))
    warn_skipped(id, skipped)

    models =
      models
      |> Enum.map(&%{&1 | provider: provider})
      |> apply_filter()
      |> Enum.sort_by(& &1.id)

    {provider, models}
  end

  @doc """
  Registers one model under its (loaded) provider.
  """
  @spec put_model(Model.t()) :: :ok
  def put_model(%Model{provider: %Provider{id: id}} = model) do
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
        {%{provider | id: id, dialects: normalize_dialects!(id, provider.dialects)}, models, true}

      {:error, :unknown_provider} ->
        {%Provider{id: id}, [], false}

      {:error, reason} ->
        Logger.warning(
          "Omni: failed to fetch provider #{inspect(id)} from #{inspect(source)} " <>
            "(#{inspect(reason)}) — loading it from config alone"
        )

        {%Provider{id: id}, [], false}
    end
  end

  # -- Merging ----------------------------------------------------------------

  # Values replace; headers merge by key, dialects by capability (the list
  # replaces), models by id.
  defp merge_config(a, b) do
    Map.merge(a, b, fn
      :headers, x, y -> Map.merge(x, y)
      :dialects, x, y -> Map.merge(x, y)
      :models, x, y -> merge_entries(x, y)
      _key, _x, y -> y
    end)
  end

  defp merge_entries(a, b) do
    ids = MapSet.new(b, & &1.id)
    Enum.reject(a, &MapSet.member?(ids, &1.id)) ++ b
  end

  defp merge_provider(%Provider{} = provider, config) do
    Enum.reduce(config, provider, fn
      {:headers, headers}, acc -> %{acc | headers: Map.merge(acc.headers, headers)}
      {:dialects, dialects}, acc -> %{acc | dialects: Map.merge(acc.dialects, dialects)}
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp merge_models(source_models, config_models) do
    ids = MapSet.new(config_models, & &1.id)
    Enum.reject(source_models, &MapSet.member?(ids, &1.id)) ++ config_models
  end

  defp config_models(id, entries) do
    Enum.map(entries, fn entry ->
      try do
        entry |> Map.put_new(:name, entry.id) |> Model.new()
      rescue
        e in [KeyError, ArgumentError] ->
          raise ArgumentError,
                "invalid model #{inspect(entry.id)} for provider #{inspect(id)} in " <>
                  "config :omni, :providers — #{Exception.message(e)}"
      end
    end)
  end

  # -- Dialects ---------------------------------------------------------------

  # Model data decides each model's dialect; the provider's list is derived
  # from its own plus its models'. A model with none takes the first of the
  # provider's own list; with no own list, it takes the dialect every other
  # model shares, if there is exactly one. Otherwise it stays unresolved and
  # is skipped — never guessed.
  defp resolve_dialects(provider, models) do
    capabilities =
      models
      |> Enum.flat_map(&Map.keys(&1.dialects))
      |> Enum.concat(Map.keys(provider.dialects))
      |> Enum.concat([:text])
      |> Enum.uniq()

    Enum.reduce(capabilities, {provider, models}, fn capability, {provider, models} ->
      own = Map.get(provider.dialects, capability, [])
      present = models |> Enum.map(&Map.get(&1.dialects, capability)) |> Enum.reject(&is_nil/1)

      fallback =
        case {own, Enum.uniq(present)} do
          {[first | _], _} -> first
          {[], [only]} -> only
          _ -> nil
        end

      models =
        if fallback,
          do: Enum.map(models, &%{&1 | dialects: Map.put_new(&1.dialects, capability, fallback)}),
          else: models

      derived = Enum.uniq(own ++ Enum.map(models, &Map.get(&1.dialects, capability)))

      dialects =
        case Enum.reject(derived, &is_nil/1) do
          [] -> Map.delete(provider.dialects, capability)
          list -> Map.put(provider.dialects, capability, list)
        end

      {%{provider | dialects: dialects}, models}
    end)
  end

  # -- Defaults and validation ------------------------------------------------

  defp fill_defaults(%Provider{id: id} = provider, found?) do
    tier =
      cond do
        Builtins.builtin?(id) -> :verified
        found? -> :catalog
        true -> :custom
      end

    %{
      provider
      | auth: provider.auth || :dialect,
        name: provider.name || to_string(id),
        tier: tier
    }
  end

  defp validate_provider!(%Provider{id: id} = provider, models, found?) do
    unless is_binary(provider.base_url) do
      where =
        if found?, do: "the catalog has no base URL for it", else: "it is not in the catalog"

      raise ArgumentError,
            "provider #{inspect(id)} has no base_url — #{where}. Set one: " <>
              "config :omni, :providers, #{id}: [base_url: \"https://...\"]"
    end

    case {Map.get(provider.dialects, :text, []), models} do
      {[], []} ->
        Logger.warning("Omni: provider #{inspect(id)} loaded no models")

      {[], _models} ->
        raise ArgumentError,
              "provider #{inspect(id)} has no dialect for its models. Set one: " <>
                "config :omni, :providers, #{id}: [dialects: %{text: Omni.Dialects.OpenAICompletions}]"

      _ ->
        :ok
    end

    for {_capability, dialects} <- provider.dialects, dialect <- dialects do
      validate_dialect!(id, dialect)
    end

    validate_auth!(id, provider.auth)
  end

  defp validate_dialect!(id, dialect) do
    unless is_atom(dialect) and Code.ensure_loaded?(dialect) and
             function_exported?(dialect, :handle_body, 3) and
             function_exported?(dialect, :auth, 0) do
      raise ArgumentError,
            "provider #{inspect(id)}: #{inspect(dialect)} is not an Omni.Dialect module"
    end
  end

  defp validate_auth!(_id, auth) when auth in [:bearer, :none, :dialect], do: :ok
  defp validate_auth!(_id, {:header, name}) when is_binary(name), do: :ok

  defp validate_auth!(id, auth) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid auth #{inspect(auth)} — expected :bearer, " <>
            "{:header, name}, :none, or :dialect"
  end

  defp warn_skipped(_id, []), do: :ok

  defp warn_skipped(id, skipped) do
    Logger.warning(
      "Omni: provider #{inspect(id)}: skipped #{length(skipped)} models with no dialect " <>
        "(#{Enum.map_join(skipped, ", ", & &1.id)}) — set dialects: in " <>
        "config :omni, :providers, #{id}: [...]"
    )
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

    Map.new(config, fn {key, value} ->
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

  defp unknown_key_message(id, key, allowed, where) do
    "provider #{inspect(id)} in #{where}: unknown key #{inspect(key)} — " <>
      "expected one of #{inspect(allowed)}"
  end

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

  defp normalize_value!(id, key, value) when key in [:headers, :models] do
    raise ArgumentError, "provider #{inspect(id)}: invalid #{key} #{inspect(value)}"
  end

  defp normalize_value!(_id, _key, value), do: value

  # %{text: Mod} and %{text: [Mod]} (or keyword lists) → %{text: [Mod]}
  defp normalize_dialects!(id, dialects) when is_list(dialects) or is_map(dialects) do
    Map.new(dialects, fn
      {capability, modules} when is_atom(capability) and is_list(modules) ->
        {capability, modules}

      {capability, module} when is_atom(capability) and is_atom(module) and not is_nil(module) ->
        {capability, [module]}

      other ->
        raise ArgumentError, "provider #{inspect(id)}: invalid dialects entry #{inspect(other)}"
    end)
  end

  defp normalize_dialects!(id, other) do
    raise ArgumentError,
          "provider #{inspect(id)}: invalid dialects #{inspect(other)} — expected " <>
            "%{text: Module} or %{text: [Module, ...]}"
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

    Keys: #{inspect(@config_keys)}. base_url values now include the API \
    version segment (e.g. "https://api.openai.com/v1").
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
            togetherai: [base_url: "https://api.together.xyz/v1"]

    Got: #{inspect(config)}
    """
  end
end
