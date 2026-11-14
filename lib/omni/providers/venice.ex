defmodule Omni.Providers.Venice do
  @moduledoc false

  # The built-in `:venice` provider: the Venice AI API, over Chat Completions.
  #
  # Venice extracts the text of a PDF itself, whatever the model's own
  # modalities, so `models/2` adds `:pdf` to every model's input.
  #
  # Users read about it in the "Venice AI" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "VENICE_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.venice.ai/api/v1",
          compat: [
            # Venice recommends `reasoning: {enabled: false}` over
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
