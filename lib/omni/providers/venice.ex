defmodule Omni.Providers.Venice do
  @moduledoc false

  # Provider for the Venice AI API, using the `Omni.Dialects.OpenAICompletions`
  # dialect.
  #
  # Reasoning:
  #
  # `:thinking` is supported. Thinking is switched off with
  # `reasoning: {enabled: false}`, which Venice recommends over
  # `reasoning_effort: "none"`. Earlier reasoning is sent back in the
  # `reasoning_content` field of assistant messages.
  #
  # PDF input:
  #
  # Every Venice model accepts PDF attachments: Venice extracts the text itself,
  # whatever the model's own modalities. The module adds `:pdf` to each model's
  # input modalities when the provider loads.
  #
  # What users are told is the "Venice AI" section of
  # guides/built-in-providers.md; keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "VENICE_API_KEY"},
      # Venice recommends `reasoning: {enabled: false}` over
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.venice.ai/api/v1",
          compat: [
            # `reasoning_effort: "none"`, which has limited support.
            thinking_toggle_format: :reasoning_enabled,
            thinking_replay_format: :reasoning_content
          ]
        ]
      }
    ]
  end

  @impl true
  def models(models, _provider) do
    Enum.map(models, fn model ->
      case :pdf in model.input_modalities do
        true -> model
        false -> Map.update!(model, :input_modalities, &[:pdf | &1])
      end
    end)
  end
end
