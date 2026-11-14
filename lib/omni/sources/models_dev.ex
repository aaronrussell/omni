defmodule Omni.Sources.ModelsDev do
  @moduledoc """
  The default model source, reading a bundled models.dev snapshot.

  The snapshot (`priv/models/models_dev.json`) is a verbatim capture of the
  [models.dev](https://models.dev) catalog's chat and decision models
  (`api.json?type=chat,decision`). Every Omni release ships a fresh
  snapshot, with data-only patch releases for notable catalog changes and at
  least one release per month; use live mode (below) when you need fresher
  data than the release cadence provides.

  The snapshot is transformed into `%Omni.Model{}` structs at load time.
  Each model loads for one capability, by its catalog `type`:

  - **text** — no type, or `"chat"`: the model must support tool use and
    take and produce text.
  - **decision** — `"decision"`: the model must take text; tool use
    doesn't apply.

  Deprecated models and every other type (image, embedding, speech,
  realtime, ...) are left out. Modalities are narrowed to those Omni
  supports, and each model's dialect is inferred from models.dev's npm
  package metadata — the model's own package if it has one, otherwise its
  provider's. Decision models read a separate table, since the same package
  names another API for decisions: `@ai-sdk/typesafe-ai` is System One and
  `@ai-sdk/openai` is OpenAI Decisions. Models that can't be represented
  faithfully are skipped with a warning: those whose npm package maps to no
  dialect Omni speaks for their capability, and those served from a
  different URL than the first model of their dialect.

  Provider ids are translated mechanically to models.dev keys —
  `:fireworks_ai` becomes `"fireworks-ai"`. Any catalog id works, including
  providers Omni ships no module for (see `Omni.Provider`). The catalog's
  provider record supplies the provider's name, API key environment variable
  (when exactly one is listed), and provider-level dialect. Each dialect's
  endpoint takes its models' URL: a model's own `provider.api` when it has
  one, otherwise the provider's `api`. Templated URLs (`${VAR}`) are kept
  for `host:` to fill.

  ## Options

  - `:live` - when `true`, fetch fresh catalog data from models.dev at
    load time instead of reading the bundled snapshot. Defaults to `false`.
  - `:cache_ttl` - how long a cached live catalog stays fresh, in
    milliseconds. Defaults to `to_timeout(hour: 24)`; `0` means always
    fetch. Ignored unless `live: true`.
  - `:cache_dir` - directory for the live catalog cache. Defaults to a
    per-user directory under `System.tmp_dir!()` (e.g. `/tmp/omni_alice`).
    Ignored unless `live: true`.

  ## Live mode

  ```elixir
  config :omni, :models,
    source: {Omni.Sources.ModelsDev, live: true}
  ```

  Live mode fetches the same catalog data over HTTPS and caches the
  response on disk. Each load walks a resilience ladder, logging a warning
  at every degradation step:

  1. Cache fresh (younger than `:cache_ttl`) — use it, no network.
  2. Cache stale or missing — fetch from models.dev; on success, write the
     cache and use the fetched data.
  3. Fetch failed — use the stale cache (stale beats empty).
  4. No usable cache — fall back to the bundled snapshot.

  The fetch runs synchronously inside `:omni`'s application start, so live
  mode adds network egress at boot and — when the cache is cold and
  models.dev is unreachable — up to ~5 seconds of boot latency. The request
  budget is fixed (no retries) and deliberately not configurable: failure
  always degrades down the ladder instead of crashing the boot.

  The cache file is the raw api.json response, replaced atomically and
  validated before use. Deleting it at any time is safe, and an unreadable
  cache is treated as missing. Cache write failures never fail a load — the
  fetched data is simply used in-memory for that boot.
  """

  @behaviour Omni.Source

  require Logger

  alias Omni.{Model, Provider, Source}

  @snapshot_file "priv/models/models_dev.json"

  # Chat models (no type, or "chat") and decision models only — the
  # catalog's image, embedding, speech and other types are left out.
  @api_url "https://models.dev/api.json?type=chat,decision"
  @cache_file "models_dev.json"
  @default_cache_ttl to_timeout(hour: 24)

  # Fixed ~5s total request budget for live fetches — deliberately not
  # configurable; failure is soft via the resilience ladder, and the
  # {module, opts} config form leaves room to add a knob later.
  @connect_timeout 2_000
  @receive_timeout 3_000

  @npm_to_dialect %{
    "@ai-sdk/alibaba" => "openai_completions",
    "@ai-sdk/anthropic" => "anthropic_messages",
    "@ai-sdk/google" => "google_generate_content",
    "@ai-sdk/groq" => "openai_completions",
    "@ai-sdk/mistral" => "openai_completions",
    "@ai-sdk/openai" => "openai_responses",
    "@ai-sdk/openai-compatible" => "openai_completions",
    "@ai-sdk/togetherai" => "openai_completions",
    "@ai-sdk/xai" => "openai_responses",
    "@openrouter/ai-sdk-provider" => "openai_completions",
    "venice-ai-sdk-provider" => "openai_completions"
  }

  # Decision models are matched separately: the same package names another
  # API for decisions (`@ai-sdk/openai` is Responses for text, Decisions for
  # decisions). A decision model whose package isn't here is skipped.
  @decision_npm_to_dialect %{
    "@ai-sdk/openai" => "openai_decisions",
    "@ai-sdk/typesafe-ai" => "typesafe_system_one"
  }

  @supported_input_modalities Enum.map(Model.supported_modalities(:input), &to_string/1)
  @supported_output_modalities Enum.map(Model.supported_modalities(:output), &to_string/1)

  @impl Omni.Source
  def fetch(id, opts) when is_atom(id) do
    catalog_id = id |> to_string() |> String.replace("_", "-")

    with {:ok, provider_data} <- lookup(catalog_id, opts) do
      {endpoints, models} = transform(provider_data, catalog_id)

      provider = %Provider{
        id: id,
        name: provider_data["name"],
        api_key: api_key(provider_data["env"]),
        dialects: endpoints
      }

      {:ok, provider, models}
    end
  end

  # Only an unambiguous single variable becomes the default key; providers
  # listing several (alternatives or multi-part credentials) need config.
  defp api_key([env_var]) when is_binary(env_var), do: {:system, env_var}
  defp api_key(_), do: nil

  defp lookup(catalog_id, opts) do
    case Map.fetch(catalog(opts), catalog_id) do
      {:ok, provider_data} -> {:ok, provider_data}
      :error -> {:error, :unknown_provider}
    end
  end

  # The decoded catalog (~9 MB of terms) is memoized for the duration of a
  # load pass — fetch/2 runs once per provider — and garbage collected when
  # the pass ends, instead of lingering for the VM's lifetime. The live
  # config is part of the memo key: providers with identical live opts share
  # one fetch per pass, while per-provider overrides with different opts fetch
  # separately.
  defp catalog(opts) do
    if Keyword.get(opts, :live, false) do
      cfg = live_config(opts)
      Omni.Source.memo({__MODULE__, :catalog, cfg}, fn -> live_catalog(cfg) end)
    else
      bundled_catalog()
    end
  end

  # Stable key so the live-mode fallback (ladder rung 4) and any live: false
  # providers in the same pass share one decode.
  defp bundled_catalog do
    Omni.Source.memo({__MODULE__, :catalog, :bundled}, fn ->
      :omni
      |> Application.app_dir(@snapshot_file)
      |> File.read!()
      |> JSON.decode!()
    end)
  end

  defp live_config(opts) do
    %{
      cache_dir: Keyword.get(opts, :cache_dir) || default_cache_dir(),
      cache_ttl: Keyword.get(opts, :cache_ttl, @default_cache_ttl),
      # Test-only HTTP injection seam, mirroring the request pipeline's
      # plug: option; not part of the documented options.
      plug: Keyword.get(opts, :plug)
    }
  end

  # System.tmp_dir!() is per-user on macOS but typically the shared /tmp on
  # Linux — suffix with the user name so two users on one host don't fight
  # over cache file ownership.
  defp default_cache_dir do
    user = System.get_env("USER") || System.get_env("USERNAME") || "default"
    Path.join(System.tmp_dir!(), "omni_#{user}")
  end

  # The live resilience ladder: fresh cache → fetch (writing the cache) →
  # stale cache → bundled snapshot, warning at each degradation step.
  defp live_catalog(cfg) do
    cache_path = Path.join(cfg.cache_dir, @cache_file)

    case read_fresh_cache(cache_path, cfg.cache_ttl) do
      {:ok, catalog} -> catalog
      :miss -> fetch_and_cache(cache_path, cfg)
    end
  end

  defp read_fresh_cache(path, ttl) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- (System.system_time(:second) - mtime) * 1000 < ttl,
         {:ok, catalog} <- read_cache(path) do
      Logger.debug("Omni.Sources.ModelsDev: using cached live catalog at #{path}")
      {:ok, catalog}
    else
      _ -> :miss
    end
  end

  defp read_cache(path) do
    with {:ok, body} <- File.read(path),
         {:ok, catalog} when is_map(catalog) <- JSON.decode(body) do
      {:ok, catalog}
    else
      {:error, :enoent} ->
        :error

      other ->
        Logger.warning(
          "Omni.Sources.ModelsDev: ignoring unreadable live-catalog cache at #{path} " <>
            "(#{inspect(other)})"
        )

        :error
    end
  end

  defp fetch_and_cache(cache_path, cfg) do
    case fetch_live(cfg) do
      {:ok, body, catalog} ->
        write_cache(cache_path, body)
        catalog

      {:error, reason} ->
        stale_or_bundled(cache_path, reason)
    end
  end

  defp fetch_live(cfg) do
    req_opts = [
      decode_body: false,
      # Req retries transient errors 3x by default, which would blow the
      # fixed request budget.
      retry: false,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout
    ]

    req_opts = if cfg.plug, do: Keyword.put(req_opts, :plug, cfg.plug), else: req_opts

    case Req.get(@api_url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Validate before caching — a body that doesn't decode to a map is a
        # fetch failure and is never written to disk.
        case JSON.decode(body) do
          {:ok, catalog} when is_map(catalog) -> {:ok, body, catalog}
          _ -> {:error, :invalid_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Best-effort with atomic replacement: the temp file lives in the target
  # directory so the rename is same-filesystem, and a write failure never
  # fails the load.
  defp write_cache(path, body) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, "#{@cache_file}.tmp.#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        Logger.warning(
          "Omni.Sources.ModelsDev: could not write live-catalog cache at #{path} " <>
            "(#{inspect(reason)}) — using fetched data for this boot only"
        )

        :ok
    end
  end

  defp stale_or_bundled(cache_path, reason) do
    case read_cache(cache_path) do
      {:ok, catalog} ->
        Logger.warning(
          "Omni.Sources.ModelsDev: live fetch from #{@api_url} failed " <>
            "(#{inspect(reason)}); using stale cache at #{cache_path}"
        )

        catalog

      :error ->
        Logger.warning(
          "Omni.Sources.ModelsDev: live fetch from #{@api_url} failed " <>
            "(#{inspect(reason)}) and no usable cache exists; falling back to the " <>
            "bundled snapshot"
        )

        bundled_catalog()
    end
  end

  @doc false
  @spec transform_provider(map(), String.t()) :: [Model.t()]
  def transform_provider(provider_data, catalog_id) do
    {_endpoints, models} = transform(provider_data, catalog_id)
    models
  end

  defp transform(provider_data, catalog_id) do
    {pairs, skipped} =
      provider_data
      |> get_models()
      |> Enum.flat_map(fn model_data ->
        case capability(model_data) do
          nil -> []
          capability -> [{model_data, capability}]
        end
      end)
      |> Enum.reduce({[], 0}, fn {model_data, capability}, {pairs, skipped} ->
        case build(model_data, capability, provider_data, catalog_id) do
          {:ok, model} -> {[{model, get_in(model_data, ["provider", "api"])} | pairs], skipped}
          :skip -> {pairs, skipped + 1}
        end
      end)

    provider_dialect =
      case @npm_to_dialect[provider_data["npm"]] do
        nil -> nil
        name -> Omni.Dialect.get!(name)
      end

    {endpoints, models, off_mount} =
      Source.endpoints(pairs, provider_data["api"], provider_dialect)

    for {model, url} <- off_mount do
      skip(catalog_id, %{"id" => model.id}, "served from #{url}, not its dialect's endpoint")
    end

    skipped = skipped + length(off_mount)

    if skipped > 0 do
      Logger.warning(
        "Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models, " <>
          "skipped #{skipped}"
      )
    else
      Logger.debug("Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models")
    end

    {endpoints, Enum.sort_by(models, & &1.id)}
  end

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  # The capability a catalog model is loaded for, or nil to leave it out.
  # Text models (no type, or "chat") must take tools and text in and out;
  # decision models need neither tools nor text output. Other types (image,
  # embedding, realtime, ...) are left out. The URL already filters by type,
  # but a live cache written from the unfiltered URL may still hold them.
  defp capability(%{"status" => "deprecated"}), do: nil

  defp capability(model) when is_map(model) do
    text_in? = "text" in modality_list(model, "input")

    case model["type"] do
      type when type in [nil, "chat"] ->
        if model["tool_call"] == true and text_in? and "text" in modality_list(model, "output"),
          do: :text

      "decision" ->
        if text_in?, do: :decision

      _other ->
        nil
    end
  end

  defp capability(_), do: nil

  defp modality_list(model, key) do
    case model["modalities"] do
      %{^key => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp build(model_data, capability, provider_data, catalog_id) do
    with {:ok, dialect} <- model_dialect(model_data, capability, provider_data) do
      {:ok, Source.build_model(model_data(model_data, dialect))}
    else
      {:skip, reason} ->
        skip(catalog_id, model_data, reason)

      {:skip_quietly, reason} ->
        Logger.debug(
          "Omni.Sources.ModelsDev: skipping #{catalog_id}:#{model_data["id"]}: #{reason}"
        )

        :skip
    end
  rescue
    e -> skip(catalog_id, model_data, Exception.message(e))
  end

  defp skip(catalog_id, model_data, reason) do
    Logger.warning(
      "Omni.Sources.ModelsDev: skipping #{catalog_id}:#{model_data["id"]}: #{reason}"
    )

    :skip
  end

  # A model's own npm package overrides its provider's. A package that maps
  # to no dialect means the catalog says the model speaks an API Omni has no
  # dialect for, so the model is skipped.
  # When the provider's own package is the unmapped one, every model it
  # doesn't override is skipped, so those go to the debug log and the
  # warning summary counts them.
  defp model_dialect(model_data, capability, provider_data) do
    table = if capability == :decision, do: @decision_npm_to_dialect, else: @npm_to_dialect

    case get_in(model_data, ["provider", "npm"]) do
      nil ->
        case table[provider_data["npm"]] do
          nil ->
            {:skip_quietly,
             "provider npm package #{inspect(provider_data["npm"])} maps to no " <>
               dialect_kind(capability)}

          dialect ->
            {:ok, dialect}
        end

      npm ->
        case table[npm] do
          nil -> {:skip, "npm package #{npm} maps to no #{dialect_kind(capability)}"}
          dialect -> {:ok, dialect}
        end
    end
  end

  defp dialect_kind(:text), do: "dialect"
  defp dialect_kind(:decision), do: "decision dialect"

  defp model_data(model_data, dialect) do
    cost = model_data["cost"] || %{}
    limit = model_data["limit"] || %{}

    %{
      "id" => model_data["id"],
      "name" => model_data["name"],
      "reasoning" => model_data["reasoning"] || false,
      "reasoning_options" => model_data["reasoning_options"],
      "release_date" => model_data["release_date"],
      "dialects" => [dialect],
      "input_modalities" =>
        filter_modalities(modality_list(model_data, "input"), @supported_input_modalities),
      "output_modalities" =>
        filter_modalities(modality_list(model_data, "output"), @supported_output_modalities),
      "input_cost" => cost["input"] || 0,
      "output_cost" => cost["output"] || 0,
      "cache_read_cost" => cost["cache_read"] || 0,
      "cache_write_cost" => cost["cache_write"] || 0,
      "context_size" => limit["context"] || 0,
      "max_output_tokens" => limit["output"] || 0
    }
  end

  # Filters modality strings before Source.build_model/1 atomizes them —
  # the unpruned snapshot carries modalities Omni has no atoms for.
  defp filter_modalities(modalities, supported) do
    Enum.filter(modalities, &(&1 in supported))
  end
end
