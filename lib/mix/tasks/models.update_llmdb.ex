defmodule Mix.Tasks.Models.UpdateLlmdb do
  @moduledoc false

  require Logger
  use Mix.Task

  # Experimental alternative to models.update that sources model data from the
  # llm_db package's bundled snapshot instead of the models.dev API. Writes to
  # priv/models-llmdb/ — nothing reads that directory at runtime.
  #
  # Evaluated 2026-07 and shelved in favour of models.dev because:
  # - the bundled snapshot lags models.dev, and llm_db's release cadence is
  #   unclear (e.g. claude-sonnet-5 was still missing a week after release)
  # - dialect inference needs a cascade of signals (execution wire_protocol,
  #   then extra.provider.npm, then per-provider fallback) and upstream
  #   wire_protocol has known errors (e.g. gpt-5.x-codex labelled openai_chat)
  # - capabilities.reasoning.enabled is unreliable upstream — worked around
  #   via extra fields (see reasoning?/1)
  #
  # Kept because this transform is the prototype for the planned runtime
  # "populate the model store from llm_db" feature (config :omni, :llmdb).

  @output_dir "priv/models-llmdb"

  @supported_dialects [
    "anthropic_messages",
    "google_gemini",
    "ollama_chat",
    "openai_completions",
    "openai_responses"
  ]

  @fallback_dialects %{
    moonshot: "openai_completions",
    nearai: "openai_completions",
    opencode: "openai_completions"
  }

  @fallback_providers Map.keys(@fallback_dialects)

  @builtin_providers Enum.sort(Omni.Provider.builtin_providers())
  @supported_input_modalities Omni.Model.supported_modalities(:input)
  @supported_output_modalities Omni.Model.supported_modalities(:output)

  @impl Mix.Task
  def run(_args) do
    # Load the LLMDB models first
    LLMDB.load()

    for {provider_id, _provider_mod} <- @builtin_providers do
      models =
        provider_id
        |> llmdb_provider()
        |> LLMDB.models()
        |> Enum.reject(&LLMDB.Model.retired?/1)
        |> Enum.filter(&(chat?(&1) and tools?(&1)))
        |> Enum.sort_by(& &1.id)
        |> Enum.flat_map(fn model ->
          data = transform_model(model, provider_id)
          aliases = Enum.map(model.aliases, &Map.put(data, "id", &1))
          [data | aliases]
        end)
        |> Enum.reject(&is_nil(&1["dialect"]))

      file = Path.join(@output_dir, "#{provider_id}.json")
      json = Jason.encode!(models, pretty: true)
      File.write!(file, json <> "\n")

      Mix.shell().info("#{provider_id}: wrote #{length(models)} models to #{file}")
    end
  end

  # Omni -> LLMDB provider id mapping
  defp llmdb_provider(:moonshot), do: :moonshotai
  defp llmdb_provider(:ollama), do: :ollama_cloud
  defp llmdb_provider(provider_id), do: provider_id

  defp transform_model(%{modalities: %{input: input, output: output}} = model, provider) do
    cost = model.cost || %{}
    limits = model.limits

    %{
      "id" => model.id,
      "name" => String.replace(model.name, ~r/^[\w\s]+:\s*/, ""),
      "reasoning" => reasoning?(model),
      "release_date" => model.release_date,
      "dialect" => infer_dialect(model, provider),
      "input_modalities" => filter_modalities(input, @supported_input_modalities),
      "output_modalities" => filter_modalities(output, @supported_output_modalities),
      "input_cost" => Map.get(cost, :input, 0) |> max(0),
      "output_cost" => Map.get(cost, :output, 0) |> max(0),
      "cache_read_cost" => Map.get(cost, :cache_read, 0) |> max(0),
      "cache_write_cost" => Map.get(cost, :cache_write, 0) |> max(0),
      "context_size" => Map.get(limits, :context, 0),
      "max_output_tokens" => Map.get(limits, :output, 0)
    }
  end

  defp infer_dialect(
         %{execution: %{text: %{supported: true, wire_protocol: wire}}} = model,
         provider
       ) do
    case wire do
      "openai_chat" ->
        "openai_completions"

      "google_generate_content" ->
        "google_gemini"

      dialect when dialect in @supported_dialects ->
        dialect

      _ ->
        Logger.warning("Unknown dialect: #{provider}:#{model.id} [wire=#{wire}]")
        nil
    end
  end

  defp infer_dialect(%{extra: %{provider: %{npm: npm}}} = model, provider) do
    case npm do
      "@ai-sdk/anthropic" ->
        "anthropic_messages"

      "@ai-sdk/openai" ->
        "openai_responses"

      "@ai-sdk/openai-compatible" ->
        "openai_completions"

      "@ai-sdk/alibaba" ->
        "openai_completions"

      "@ai-sdk/google" ->
        "google_gemini"

      _ ->
        Logger.warning("Unknown dialect: #{provider}:#{model.id} [npm=#{npm}]")
        nil
    end
  end

  defp infer_dialect(_model, provider) when provider in @fallback_providers do
    @fallback_dialects[provider]
  end

  defp infer_dialect(model, provider) do
    Logger.warning("Unknown dialect: #{provider}:#{model.id} [fallback]")
    nil
  end

  defp filter_modalities(modalities, supported) do
    modalities
    |> Enum.filter(&(&1 in supported))
    |> Enum.map(&to_string/1)
  end

  defp chat?(%{capabilities: %{chat: true}}), do: true
  defp chat?(_model), do: false

  defp tools?(%{capabilities: %{tools: %{enabled: true}}}), do: true
  defp tools?(_model), do: false

  # Sometimes llm_db incorrectly states reasoning: false on some models we know
  # that is incorrect. This is hopefully a temporary solution.
  defp reasoning?(%{capabilities: capabilities} = model) do
    extra = model.extra || %{}
    extra_reasoning = if is_map(extra[:reasoning]), do: extra[:reasoning], else: %{}

    match?(%{reasoning: %{enabled: true}}, capabilities) or
      extra_reasoning[:mandatory] == true or
      (extra_reasoning[:supported_efforts] || []) != [] or
      (extra[:reasoning_options] || []) != []
  end
end
