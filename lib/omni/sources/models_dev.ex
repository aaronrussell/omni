defmodule Omni.Sources.ModelsDev do
  @moduledoc """
  The default model source, reading a bundled models.dev snapshot.

  The snapshot (`priv/models/models_dev.json`) is a verbatim capture of the
  full [models.dev](https://models.dev) catalog, refreshed with
  `mix omni.snapshot`. Every Omni release ships a fresh snapshot, with
  data-only patch releases for notable catalog changes and at least one
  release per month; use live mode (below) when you need fresher data than
  the release cadence provides. The snapshot is transformed into
  `%Omni.Model{}` structs at load time: deprecated models and those without tool use or text modalities are
  filtered out, modalities are narrowed to those Omni supports, and each
  model's dialect is inferred from models.dev's npm package metadata, falling
  back to the provider's declared dialect. Models that still fail to build
  are skipped with a warning.

  Built-in providers are matched to their catalog entries automatically.
  Custom providers pass `provider_id:` — any models.dev catalog id works,
  including providers Omni ships no module for:

      defmodule MyApp.Providers.Mistral do
        use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

        @impl true
        def config do
          %{base_url: "https://api.mistral.ai", api_key: {:system, "MISTRAL_API_KEY"}}
        end

        @impl true
        def models, do: Omni.Provider.load_models(__MODULE__, provider_id: :mistral)
      end

  ## Options

    * `:provider_id` — the models.dev catalog id to load models from.
      Required for custom providers; built-in providers are matched
      automatically.
    * `:live` — when `true`, fetch fresh catalog data from models.dev at
      load time instead of reading the bundled snapshot. Defaults to `false`.
    * `:cache_ttl` — how long a cached live catalog stays fresh, in
      milliseconds. Defaults to `to_timeout(hour: 24)`; `0` means always
      fetch. Ignored unless `live: true`.
    * `:cache_dir` — directory for the live catalog cache. Defaults to a
      per-user directory under `System.tmp_dir!()` (e.g. `/tmp/omni_alice`).
      Ignored unless `live: true`.

  ## Live mode

      config :omni, :models,
        source: {Omni.Sources.ModelsDev, live: true}

  Live mode fetches the full models.dev catalog over HTTPS and caches the
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

  alias Omni.{Model, Provider}

  @snapshot_file "priv/models/models_dev.json"

  @api_url "https://models.dev/api.json"
  @cache_file "models_dev.json"
  @default_cache_ttl to_timeout(hour: 24)

  # Fixed ~5s total request budget for live fetches — deliberately not
  # configurable; failure is soft via the resilience ladder, and the
  # {module, opts} config form leaves room to add a knob later.
  @connect_timeout 2_000
  @receive_timeout 3_000

  # Omni provider id -> models.dev catalog key
  @renames %{moonshot: "moonshotai", ollama: "ollama-cloud"}

  @npm_to_dialect %{
    "@ai-sdk/alibaba" => "openai_completions",
    "@ai-sdk/anthropic" => "anthropic_messages",
    "@ai-sdk/google" => "google_gemini",
    "@ai-sdk/groq" => "openai_completions",
    "@ai-sdk/openai" => "openai_responses",
    "@ai-sdk/openai-compatible" => "openai_completions",
    "@openrouter/ai-sdk-provider" => "openai_completions",
    "venice-ai-sdk-provider" => "openai_completions"
  }

  @supported_input_modalities Enum.map(Model.supported_modalities(:input), &to_string/1)
  @supported_output_modalities Enum.map(Model.supported_modalities(:output), &to_string/1)

  @impl Omni.Source
  def fetch(module, opts) do
    with {:ok, catalog_id} <- resolve_catalog_id(module, opts),
         {:ok, provider_data} <- lookup(catalog_id, opts) do
      {:ok, transform_provider(provider_data, module, catalog_id)}
    end
  end

  defp resolve_catalog_id(module, opts) do
    case Keyword.fetch(opts, :provider_id) do
      {:ok, id} ->
        {:ok, to_string(id)}

      :error ->
        case Enum.find(Provider.builtin_providers(), fn {_id, mod} -> mod == module end) do
          {omni_id, _mod} -> {:ok, @renames[omni_id] || to_string(omni_id)}
          nil -> {:error, :unknown_provider}
        end
    end
  end

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
  # one fetch per pass, while per-module overrides with different opts fetch
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
  @spec transform_provider(map(), module(), String.t()) :: [Model.t()]
  def transform_provider(provider_data, module, catalog_id) do
    {models, skipped} =
      provider_data
      |> get_models()
      |> Enum.filter(&eligible?/1)
      |> Enum.reduce({[], 0}, fn model_data, {models, skipped} ->
        case build(model_data, module, provider_data, catalog_id) do
          {:ok, model} -> {[model | models], skipped}
          :skip -> {models, skipped + 1}
        end
      end)

    if skipped > 0 do
      Logger.warning(
        "Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models, " <>
          "skipped #{skipped}"
      )
    else
      Logger.debug("Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models")
    end

    Enum.sort_by(models, & &1.id)
  end

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  defp eligible?(model) when is_map(model) do
    model["status"] != "deprecated" and model["tool_call"] == true and
      "text" in modality_list(model, "input") and "text" in modality_list(model, "output")
  end

  defp eligible?(_), do: false

  defp modality_list(model, key) do
    case model["modalities"] do
      %{^key => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp build(model_data, module, provider_data, catalog_id) do
    cost = model_data["cost"] || %{}
    limit = model_data["limit"] || %{}
    npm = get_in(model_data, ["provider", "npm"]) || provider_data["npm"]

    data = %{
      "id" => model_data["id"],
      "name" => model_data["name"],
      "reasoning" => model_data["reasoning"] || false,
      "release_date" => model_data["release_date"],
      "dialect" => @npm_to_dialect[npm],
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

    {:ok, Provider.build_model(module, data)}
  rescue
    e ->
      Logger.warning(
        "Omni.Sources.ModelsDev: skipping #{catalog_id}:#{model_data["id"]}: " <>
          Exception.message(e)
      )

      :skip
  end

  # Filters modality strings before Provider.build_model/2 atomizes them —
  # the unpruned snapshot carries modalities Omni has no atoms for.
  defp filter_modalities(modalities, supported) do
    Enum.filter(modalities, &(&1 in supported))
  end
end
