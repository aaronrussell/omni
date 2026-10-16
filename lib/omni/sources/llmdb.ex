defmodule Omni.Sources.LLMDB do
  @moduledoc """
  Sources the model catalog from the optional
  [`llm_db`](https://hex.pm/packages/llm_db) package.

  Select it globally or per provider:

      config :omni, :models, source: Omni.Sources.LLMDB

      # keep one provider on the bundled snapshot
      config :omni, :providers, openai: [source: Omni.Sources.ModelsDev]

  llm_db must be in your deps — selecting this source without the package
  raises at boot:

      {:llm_db, "~> 2026.7"}

  Models are read from llm_db's catalog store and transformed at load time:
  retired models and those without tool use or text modalities are filtered
  out (deprecated models are kept — they remain callable), aliases are
  expanded so friendly ids keep resolving (canonical records win on id
  collisions), and negative cost sentinels are clamped to zero. Models that
  still fail to build are skipped with a warning.

  Model filtering and data freshness are llm_db's own concerns — Omni
  deliberately doesn't wrap them. See llm_db's `allow:`, `deny:`, and
  `sources:` configuration.

  Provider ids are llm_db's own ids — snake_cased models.dev keys — so no
  translation is applied. llm_db's provider record supplies the provider's
  name, base URL (unless it is a template such as `{region}`), and API key
  environment variable (when exactly one is listed).

  ## Dialect resolution

  Catalog data is the source of truth, resolved per model: the wire
  protocol, then npm package metadata. A model whose npm package maps to no
  dialect is skipped with a warning, as is one served from a different base
  URL than its provider; a model with no signal at all is left for Omni to
  fill from its provider. Known upstream data issue: `wire_protocol`
  mislabels some Responses-only OpenAI models as `openai_chat` — those
  models load with the Completions dialect until it's corrected upstream. (A
  second upstream issue, `capabilities.reasoning.enabled` under-reporting
  reasoning support, is systematic — a materialized schema default — and is
  worked around via `extra` signals.)
  """

  @behaviour Omni.Source

  @compile {:no_warn_undefined, [LLMDB, LLMDB.Model]}

  require Logger

  alias Omni.{Model, Provider, Source}

  # npm package -> dialect, for models of multi-dialect providers. Kept in
  # step with Omni.Sources.ModelsDev's table by hand — the two catalogs can
  # drift independently.
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

  @supported_dialects [
    "anthropic_messages",
    "google_gemini",
    "ollama_chat",
    "openai_completions",
    "openai_responses"
  ]

  # llm_db provider id -> provider-level dialect. llm_db has no provider-level
  # npm, so multi-dialect gateways need one for models that carry neither npm
  # nor wire-protocol metadata (mirrors models.dev's provider-level
  # @ai-sdk/openai-compatible on opencode).
  @gateway_fallback %{opencode: "openai_completions"}

  # llm_db modalities are atom lists — no stringifying here (compare ModelsDev)
  @supported_input_modalities Model.supported_modalities(:input)
  @supported_output_modalities Model.supported_modalities(:output)

  @impl Omni.Source
  def fetch(id, _opts) when is_atom(id) do
    ensure_llm_db!()

    case LLMDB.provider(id) do
      {:ok, llmdb_provider} ->
        provider = build_provider(id, llmdb_provider)
        {:ok, provider, transform_provider(LLMDB.models(id), id, provider.base_url)}

      {:error, :not_found} ->
        {:error, :unknown_provider}
    end
  end

  defp build_provider(id, llmdb_provider) do
    %Provider{
      id: id,
      name: llmdb_provider.name,
      base_url: base_url(llmdb_provider.base_url),
      api_key: api_key(llmdb_provider.env),
      dialects: provider_dialects(@gateway_fallback[id])
    }
  end

  # Templated base URLs ("https://{region}.example.com") need user config.
  defp base_url(url) when is_binary(url) do
    if String.contains?(url, "{"), do: nil, else: url
  end

  defp base_url(_), do: nil

  defp api_key([env_var]) when is_binary(env_var), do: {:system, env_var}
  defp api_key(_), do: nil

  defp provider_dialects(nil), do: %{}
  defp provider_dialects(name), do: %{text: [Omni.Dialect.get!(name)]}

  # The catalog lives in llm_db's own :persistent_term store, loaded by its
  # application start — reads are O(1), so unlike ModelsDev there is nothing
  # to memoize per load pass.
  defp ensure_llm_db! do
    unless Code.ensure_loaded?(LLMDB) do
      raise """
      Omni.Sources.LLMDB is configured as a model source, but the llm_db \
      package is not available. Add it to your deps:

          {:llm_db, "~> 2026.7"}

      or configure a different source:

          config :omni, :models, source: Omni.Sources.ModelsDev
      """
    end

    {:ok, _} = Application.ensure_all_started(:llm_db)
    :ok
  end

  @doc false
  @spec transform_provider([struct()], atom(), String.t() | nil) :: [Model.t()]
  def transform_provider(llmdb_models, provider_id, base_url \\ nil) do
    {entries, skipped} =
      llmdb_models
      |> Enum.filter(&eligible?/1)
      |> Enum.reduce({[], 0}, fn llmdb_model, {entries, skipped} ->
        case transform(llmdb_model, provider_id, base_url) do
          {:ok, data} ->
            aliases = Enum.map(llmdb_model.aliases || [], &Map.put(data, "id", &1))
            {[{data, aliases} | entries], skipped}

          :skip ->
            {entries, skipped + 1}
        end
      end)

    {models, skipped} =
      entries
      |> Enum.reverse()
      |> expand_aliases()
      |> Enum.reduce({[], skipped}, fn data, {models, skipped} ->
        case build(data, provider_id) do
          {:ok, model} -> {[model | models], skipped}
          :skip -> {models, skipped + 1}
        end
      end)

    if skipped > 0 do
      Logger.warning(
        "Omni.Sources.LLMDB: #{provider_id}: loaded #{length(models)} models, " <>
          "skipped #{skipped}"
      )
    else
      Logger.debug("Omni.Sources.LLMDB: #{provider_id}: loaded #{length(models)} models")
    end

    Enum.sort_by(models, & &1.id)
  end

  # Retired models are dropped; deprecated ones are kept — they remain
  # callable. (ModelsDev filters on deprecated instead; aligning the two is
  # a future decision.)
  defp eligible?(model) do
    chat?(model) and tools?(model) and not LLMDB.Model.retired?(model) and
      text_in_and_out?(model)
  end

  defp chat?(%{capabilities: %{chat: true}}), do: true
  defp chat?(_model), do: false

  defp tools?(%{capabilities: %{tools: %{enabled: true}}}), do: true
  defp tools?(_model), do: false

  defp text_in_and_out?(%{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output) do
    :text in input and :text in output
  end

  defp text_in_and_out?(_model), do: false

  # llm_db's extra field is an unmapped models.dev passthrough, fragile
  # across llm_db versions — the rescue keeps one bad model from failing the
  # whole provider.
  defp transform(model, provider_id, base_url) do
    with :ok <- check_mount(model, base_url),
         {:ok, dialect} <- infer_dialect(model) do
      cost = model.cost || %{}
      limits = model.limits || %{}
      %{input: input, output: output} = model.modalities

      {:ok,
       %{
         "id" => model.id,
         "name" => strip_provider_prefix(model.name || model.id),
         "reasoning" => reasoning?(model),
         "release_date" => model.release_date,
         "dialect" => dialect,
         "input_modalities" => filter_modalities(input, @supported_input_modalities),
         "output_modalities" => filter_modalities(output, @supported_output_modalities),
         "input_cost" => cost_for(cost, :input),
         "output_cost" => cost_for(cost, :output),
         "cache_read_cost" => cost_for(cost, :cache_read),
         "cache_write_cost" => cost_for(cost, :cache_write),
         "context_size" => Map.get(limits, :context) || 0,
         "max_output_tokens" => Map.get(limits, :output) || 0
       }}
    else
      {:skip, reason} -> skip(provider_id, model.id, reason)
    end
  rescue
    e -> skip(provider_id, model.id, Exception.message(e))
  end

  defp skip(provider_id, model_id, reason) do
    Logger.warning("Omni.Sources.LLMDB: skipping #{provider_id}:#{model_id}: #{reason}")
    :skip
  end

  # A model served from its own base URL can't use the provider's.
  defp check_mount(%{base_url: url}, base_url) when is_binary(url) and url != base_url do
    {:skip, "served from #{url}, not the provider's base URL"}
  end

  defp check_mount(_model, _base_url), do: :ok

  # Catalog data is the source of truth: the wire protocol, then npm
  # metadata. An npm package that maps to no dialect is skipped (it is the
  # model's own, so filling it from the provider would be a guess); no signal
  # at all yields nil, which Omni fills from the provider.
  defp infer_dialect(model) do
    case wire_dialect(model) do
      nil -> npm_dialect(model)
      dialect -> {:ok, dialect}
    end
  end

  defp wire_dialect(%{execution: %{text: %{supported: true, wire_protocol: wire}}}) do
    case wire do
      "openai_chat" -> "openai_completions"
      "google_generate_content" -> "google_gemini"
      wire when wire in @supported_dialects -> wire
      _ -> nil
    end
  end

  defp wire_dialect(_model), do: nil

  defp npm_dialect(%{extra: %{provider: %{npm: npm}}}) when is_binary(npm) do
    case @npm_to_dialect[npm] do
      nil -> {:skip, "npm package #{npm} maps to no dialect"}
      dialect -> {:ok, dialect}
    end
  end

  defp npm_dialect(_model), do: {:ok, nil}

  # capabilities.reasoning.enabled is a materialized schema default upstream,
  # wrong on some models — OR it with the extra passthrough signals. The list
  # checks must be non-empty checks: [] is truthy.
  defp reasoning?(%{capabilities: capabilities} = model) do
    extra = model.extra || %{}
    extra_reasoning = if is_map(extra[:reasoning]), do: extra[:reasoning], else: %{}

    match?(%{reasoning: %{enabled: true}}, capabilities) or
      extra_reasoning[:mandatory] == true or
      (extra_reasoning[:supported_efforts] || []) != [] or
      (extra[:reasoning_options] || []) != []
  end

  # Missing and nil cost entries become 0; negatives are clamped — OpenRouter
  # router models carry a -1.0e6 sentinel.
  defp cost_for(cost, key) do
    case Map.get(cost, key) do
      nil -> 0
      value -> max(value, 0)
    end
  end

  # llm_db names often carry a "Provider: " prefix ("Anthropic: Claude ...")
  defp strip_provider_prefix(name), do: String.replace(name, ~r/^[\w\s]+:\s*/, "")

  # Filters modality atoms to those Omni supports, then stringifies for
  # Source.build_model/1 (which atomizes).
  defp filter_modalities(modalities, supported) do
    modalities
    |> Enum.filter(&(&1 in supported))
    |> Enum.map(&to_string/1)
  end

  # One entry per alias with the id swapped; canonical records win on id
  # collisions, first alias wins on alias<->alias collisions.
  defp expand_aliases(entries) do
    canonicals = Enum.map(entries, fn {data, _aliases} -> data end)
    canonical_ids = MapSet.new(canonicals, & &1["id"])

    aliases =
      entries
      |> Enum.flat_map(fn {_data, aliases} -> aliases end)
      |> Enum.reject(&MapSet.member?(canonical_ids, &1["id"]))
      |> Enum.uniq_by(& &1["id"])

    canonicals ++ aliases
  end

  defp build(data, provider_id) do
    {:ok, Source.build_model(data)}
  rescue
    e -> skip(provider_id, data["id"], Exception.message(e))
  end
end
