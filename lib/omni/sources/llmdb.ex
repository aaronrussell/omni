defmodule Omni.Sources.LLMDB do
  @moduledoc """
  Sources the model catalog from the optional
  [`llm_db`](https://hex.pm/packages/llm_db) package.

  Select it globally, per provider, or at a call site:

      config :omni, :providers, source: :llm_db

      # keep one provider on the bundled snapshot
      config :omni, Omni.Providers.OpenAI, source: :models_dev

  llm_db must be in your deps — selecting this source without the package
  raises at boot:

      {:llm_db, "~> 2026.6"}

  Models are read from llm_db's catalog store and transformed at load time:
  retired models and those without tool use or text modalities are filtered
  out (deprecated models are kept — they remain callable), aliases are
  expanded so friendly ids keep resolving (canonical records win on id
  collisions), and negative cost sentinels are clamped to zero. Models that
  still fail to build are skipped with a warning.

  Model filtering and data freshness are llm_db's own concerns — Omni
  deliberately doesn't wrap them. See llm_db's `allow:`, `deny:`, and
  `sources:` configuration.

  Built-in providers are matched to their catalog entries automatically.
  Custom providers pass `provider_id:`, the llm_db catalog id:

      defmodule MyApp.Providers.Mistral do
        use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

        @impl true
        def config do
          %{base_url: "https://api.mistral.ai", api_key: {:system, "MISTRAL_API_KEY"}}
        end

        @impl true
        def models, do: Omni.Provider.load_models(__MODULE__, provider_id: :mistral)
      end

  ## Dialect resolution

  Catalog data is the source of truth, resolved per model: the wire
  protocol, then npm package metadata, then a per-gateway fallback. When no
  signal resolves, `Omni.Provider.build_model/2` falls back to the provider
  module's declared dialect; a model with no dialect after that is skipped
  with a warning. Known upstream data issue: `wire_protocol` mislabels some
  Responses-only OpenAI models as `openai_chat` — those models load with the
  Completions dialect until it's corrected upstream. (A second upstream
  issue, `capabilities.reasoning.enabled` under-reporting reasoning support,
  is systematic — a materialized schema default — and is worked around via
  `extra` signals.)
  """

  @behaviour Omni.Source

  @compile {:no_warn_undefined, [LLMDB, LLMDB.Model]}

  require Logger

  alias Omni.{Model, Provider}

  # Omni provider id -> llm_db provider id
  @renames %{moonshot: :moonshotai, ollama: :ollama_cloud}

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

  # llm_db provider id -> dialect, for models of multi-dialect gateways that
  # carry neither npm nor wire-protocol metadata (mirrors models.dev's
  # provider-level @ai-sdk/openai-compatible on opencode).
  @gateway_fallback %{opencode: "openai_completions"}

  # llm_db modalities are atom lists — no stringifying here (compare ModelsDev)
  @supported_input_modalities Model.supported_modalities(:input)
  @supported_output_modalities Model.supported_modalities(:output)

  @impl Omni.Source
  def fetch(module, opts) do
    ensure_llm_db!()

    with {:ok, provider_id} <- resolve_provider_id(module, opts),
         :ok <- lookup(provider_id) do
      {:ok, transform_provider(LLMDB.models(provider_id), module, provider_id)}
    end
  end

  # The catalog lives in llm_db's own :persistent_term store, loaded by its
  # application start — reads are O(1), so unlike ModelsDev there is nothing
  # to memoize per load pass.
  defp ensure_llm_db! do
    unless Code.ensure_loaded?(LLMDB) do
      raise """
      Omni.Sources.LLMDB is configured as a model source, but the llm_db \
      package is not available. Add it to your deps:

          {:llm_db, "~> 2026.6"}

      or configure a different source:

          config :omni, :providers, source: :models_dev
      """
    end

    {:ok, _} = Application.ensure_all_started(:llm_db)
    :ok
  end

  defp resolve_provider_id(module, opts) do
    case Keyword.fetch(opts, :provider_id) do
      {:ok, id} when is_atom(id) ->
        {:ok, id}

      {:ok, id} when is_binary(id) ->
        # llm_db ids are atoms, but a string keeps provider_id: portable
        # across sources. Every provider in the loaded catalog already has
        # its atom, so unknown strings degrade to :unknown_provider instead
        # of leaking atoms.
        try do
          {:ok, String.to_existing_atom(id)}
        rescue
          ArgumentError -> {:error, :unknown_provider}
        end

      :error ->
        case Enum.find(Provider.builtin_providers(), fn {_id, mod} -> mod == module end) do
          {omni_id, _mod} -> {:ok, @renames[omni_id] || omni_id}
          nil -> {:error, :unknown_provider}
        end
    end
  end

  defp lookup(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, _provider} -> :ok
      {:error, :not_found} -> {:error, :unknown_provider}
    end
  end

  @doc false
  @spec transform_provider([struct()], module(), atom()) :: [Model.t()]
  def transform_provider(llmdb_models, module, provider_id) do
    {entries, skipped} =
      llmdb_models
      |> Enum.filter(&eligible?/1)
      |> Enum.reduce({[], 0}, fn llmdb_model, {entries, skipped} ->
        case transform(llmdb_model, provider_id) do
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
        case build(data, module, provider_id) do
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
  defp transform(model, provider_id) do
    cost = model.cost || %{}
    limits = model.limits || %{}
    %{input: input, output: output} = model.modalities

    {:ok,
     %{
       "id" => model.id,
       "name" => strip_provider_prefix(model.name || model.id),
       "reasoning" => reasoning?(model),
       "release_date" => model.release_date,
       "dialect" => infer_dialect(model, provider_id),
       "input_modalities" => filter_modalities(input, @supported_input_modalities),
       "output_modalities" => filter_modalities(output, @supported_output_modalities),
       "input_cost" => cost_for(cost, :input),
       "output_cost" => cost_for(cost, :output),
       "cache_read_cost" => cost_for(cost, :cache_read),
       "cache_write_cost" => cost_for(cost, :cache_write),
       "context_size" => Map.get(limits, :context) || 0,
       "max_output_tokens" => Map.get(limits, :output) || 0
     }}
  rescue
    e ->
      Logger.warning(
        "Omni.Sources.LLMDB: skipping #{provider_id}:#{model.id}: " <> Exception.message(e)
      )

      :skip
  end

  # Catalog data is the source of truth: the wire protocol, then npm
  # metadata, then the gateway fallback. When no signal resolves this emits
  # nil and Provider.build_model/2 falls back to the module's declared
  # dialect; a model that still has no dialect raises there and is skipped
  # with a warning by build/3.
  defp infer_dialect(model, provider_id) do
    wire_dialect(model) || npm_dialect(model) || @gateway_fallback[provider_id]
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

  defp npm_dialect(%{extra: %{provider: %{npm: npm}}}), do: @npm_to_dialect[npm]
  defp npm_dialect(_model), do: nil

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
  # Provider.build_model/2 (which atomizes).
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

  defp build(data, module, provider_id) do
    {:ok, Provider.build_model(module, data)}
  rescue
    e ->
      Logger.warning(
        "Omni.Sources.LLMDB: skipping #{provider_id}:#{data["id"]}: " <> Exception.message(e)
      )

      :skip
  end
end
