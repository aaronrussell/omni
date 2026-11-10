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

  Models are read from llm_db's catalog store and transformed at load time.
  A model loads for text when llm_db says it chats, supports tool use and
  takes and produces text, and for decisions when it has an
  `execution.evaluate` entry; a model may qualify for both (OpenAI's
  `gpt-6-luna`). Retired models are filtered out (deprecated models are
  kept — they remain callable), as are those llm_db marks `catalog_only`
  (described, but not callable). Aliases are
  expanded so friendly ids keep resolving (canonical records win on id
  collisions), and negative cost sentinels are clamped to zero. Models that
  still fail to build are skipped with a warning.

  Model filtering and data freshness are llm_db's own concerns — Omni
  deliberately doesn't wrap them. See llm_db's `allow:`, `deny:`, and
  `sources:` configuration.

  Provider ids are llm_db's own ids — snake_cased models.dev keys — so no
  translation is applied. llm_db's provider record supplies the provider's
  name and API key environment variable (when exactly one is listed). Each
  dialect's endpoint takes its models' URL: a model's own `base_url` when it
  has one, otherwise the provider's. Templated URLs (`{region}`) are kept
  for `host:` to fill.

  ## Dialect resolution

  Catalog data is the source of truth, resolved per model and capability.
  For text: the wire protocol, then npm package metadata. For decisions:
  `execution.evaluate.family`, where `typesafe_systemone` and
  `openrouter_decisions` (OpenRouter's alpha route for the same wire) are
  System One and `openai_decisions` is OpenAI Decisions; other families are
  skipped. A model whose npm package maps to no
  dialect is skipped with a warning, as is one with no signal at all, and
  one served from a different URL than the first model of its dialect.
  Known upstream data issue: `wire_protocol`
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

  # execution.evaluate.family -> decision dialect. OpenRouter's family
  # names its alpha Decisions route, which takes the System One wire; Omni
  # sends to its stable /systemone route instead (the endpoint URL comes
  # from Omni.Providers.OpenRouter). Other families are skipped.
  @family_to_decision_dialect %{
    "openai_decisions" => "openai_decisions",
    "openrouter_decisions" => "typesafe_system_one",
    "typesafe_systemone" => "typesafe_system_one"
  }

  @supported_dialects [
    "anthropic_messages",
    "google_generate_content",
    "ollama_chat",
    "openai_completions",
    "openai_responses"
  ]

  # llm_db modalities are atom lists — no stringifying here (compare ModelsDev)
  @supported_input_modalities Model.supported_modalities(:input)
  @supported_output_modalities Model.supported_modalities(:output)

  @impl Omni.Source
  def fetch(id, _opts) when is_atom(id) do
    ensure_llm_db!()

    case LLMDB.provider(id) do
      {:ok, llmdb_provider} ->
        {endpoints, models} = transform(LLMDB.models(id), id, llmdb_provider.base_url)

        provider = %Provider{
          id: id,
          name: llmdb_provider.name,
          api_key: api_key(llmdb_provider.env),
          dialects: endpoints
        }

        {:ok, provider, models}

      {:error, :not_found} ->
        {:error, :unknown_provider}
    end
  end

  defp api_key([env_var]) when is_binary(env_var), do: {:system, env_var}
  defp api_key(_), do: nil

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
    {_endpoints, models} = transform(llmdb_models, provider_id, base_url)
    models
  end

  defp transform(llmdb_models, provider_id, base_url) do
    {entries, skipped} =
      llmdb_models
      |> Enum.filter(&eligible?/1)
      |> Enum.reduce({[], 0}, fn llmdb_model, {entries, skipped} ->
        case transform_model(llmdb_model, provider_id) do
          {:ok, data} ->
            aliases = Enum.map(llmdb_model.aliases || [], &Map.put(data, "id", &1))
            {[{data, aliases} | entries], skipped}

          :skip ->
            {entries, skipped + 1}
        end
      end)

    {pairs, skipped} =
      entries
      |> Enum.reverse()
      |> expand_aliases()
      |> Enum.reduce({[], skipped}, fn data, {pairs, skipped} ->
        case build(data, provider_id) do
          {:ok, model} -> {[{model, data["url"]} | pairs], skipped}
          :skip -> {pairs, skipped + 1}
        end
      end)

    {endpoints, models, off_mount} = Source.endpoints(pairs, base_url, nil)

    for {model, url} <- off_mount do
      skip(provider_id, model.id, "served from #{url}, not its dialect's endpoint")
    end

    skipped = skipped + length(off_mount)

    if skipped > 0 do
      Logger.warning(
        "Omni.Sources.LLMDB: #{provider_id}: loaded #{length(models)} models, " <>
          "skipped #{skipped}"
      )
    else
      Logger.debug("Omni.Sources.LLMDB: #{provider_id}: loaded #{length(models)} models")
    end

    {endpoints, Enum.sort_by(models, & &1.id)}
  end

  # Retired models are dropped; deprecated ones are kept — they remain
  # callable. (ModelsDev filters on deprecated instead; aligning the two is
  # a future decision.) Catalog-only models are ones llm_db describes but
  # says can't be called. What's left loads for text, decisions, or both.
  defp eligible?(model) do
    not LLMDB.Model.retired?(model) and Map.get(model, :catalog_only) != true and
      (text?(model) or decision?(model))
  end

  defp text?(model), do: chat?(model) and tools?(model) and text_in_and_out?(model)

  defp decision?(%{execution: %{evaluate: %{supported: true}}}), do: true
  defp decision?(_model), do: false

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
  defp transform_model(model, provider_id) do
    with {:ok, dialects} <- model_dialects(model) do
      cost = model.cost || %{}
      limits = model.limits || %{}
      %{input: input, output: output} = modalities(model)

      {:ok,
       %{
         "id" => model.id,
         "name" => strip_provider_prefix(model.name || model.id),
         "reasoning" => reasoning?(model),
         "reasoning_options" => reasoning_options(model),
         "release_date" => model.release_date,
         "dialects" => dialects,
         "url" => model.base_url,
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

  # A dialect per capability the model qualifies for. A model is skipped
  # only when it ends up with none; a decision model that also has an
  # unmappable text signal keeps its decision dialect, and vice versa.
  defp model_dialects(model) do
    results =
      [
        text?(model) && infer_dialect(model),
        decision?(model) && decision_dialect(model)
      ]
      |> Enum.filter(& &1)

    case for({:ok, dialect} <- results, do: dialect) do
      [] -> Enum.find(results, &match?({:skip, _}, &1))
      dialects -> {:ok, dialects}
    end
  end

  # llm_db's decision models carry no modalities of their own (TypeSafe) or
  # an output of [:decisions]; either way they take text in.
  defp modalities(%{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output),
       do: %{input: input, output: output}

  defp modalities(_model), do: %{input: [:text], output: [:text]}

  defp decision_dialect(%{execution: %{evaluate: %{family: family}}}) do
    case @family_to_decision_dialect[family] do
      nil -> {:skip, "decision family #{inspect(family)} maps to no decision dialect"}
      dialect -> {:ok, dialect}
    end
  end

  # Catalog data is the source of truth: the wire protocol, then npm
  # metadata. An npm package that maps to no dialect is skipped, and so is a
  # model with no signal at all: Omni never guesses a dialect.
  defp infer_dialect(model) do
    case wire_dialect(model) do
      nil -> npm_dialect(model)
      dialect -> {:ok, dialect}
    end
  end

  defp wire_dialect(%{execution: %{text: %{supported: true, wire_protocol: wire}}}) do
    case wire do
      "openai_chat" -> "openai_completions"
      wire when wire in @supported_dialects -> wire
      _ -> nil
    end
  end

  defp wire_dialect(_model), do: nil

  defp npm_dialect(model) do
    case extra(model, [:provider, :npm]) do
      npm when is_binary(npm) ->
        case @npm_to_dialect[npm] do
          nil -> {:skip, "npm package #{npm} maps to no dialect"}
          dialect -> {:ok, dialect}
        end

      _ ->
        {:skip, "no wire protocol or npm package maps to a dialect"}
    end
  end

  # capabilities.reasoning.enabled is a materialized schema default upstream,
  # wrong on some models — OR it with the extra passthrough signals. The list
  # checks must be non-empty checks: [] is truthy.
  defp reasoning?(%{capabilities: capabilities} = model) do
    match?(%{reasoning: %{enabled: true}}, capabilities) or
      extra(model, [:reasoning, :mandatory]) == true or
      list(extra(model, [:reasoning, :supported_efforts])) != [] or
      list(extra(model, [:reasoning_options])) != []
  end

  # models.dev's reasoning_options pass through as-is (Source.build_model/1
  # reads either key type); OpenRouter's supported_efforts stand in when
  # they are absent.
  defp reasoning_options(model) do
    case list(extra(model, [:reasoning_options])) do
      [] ->
        case list(extra(model, [:reasoning, :supported_efforts])) do
          [] -> nil
          efforts -> [%{"type" => "effort", "values" => Enum.map(efforts, &to_string/1)}]
        end

      options ->
        options
    end
  end

  # llm_db's extra keeps atom keys up to 2026.7.0 and JSON string keys from
  # 2026.7.2, so read either.
  defp extra(model, path) do
    Enum.reduce_while(path, model.extra, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        %{} -> {:cont, Map.get(acc, Atom.to_string(key))}
        _ -> {:halt, nil}
      end
    end)
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

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
