defmodule Omni.Providers.Venice do
  @moduledoc """
  Provider for the Venice AI API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:venice`. Reads the API key from `VENICE_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, venice: [...]` (see `Omni.Provider`).

  ## Reasoning

  `:thinking` is supported. Thinking is switched off with
  `reasoning: {enabled: false}`, which Venice recommends over
  `reasoning_effort: "none"`.

  ## PDF input

  Every Venice model accepts PDF attachments: Venice extracts the text itself,
  whatever the model's own modalities. The module adds `:pdf` to each model's
  input modalities when the provider loads.

  ## Compat flags

  Sets this `Omni.Dialects.OpenAICompletions` flag:

    * `thinking_toggle_format: :reasoning_enabled`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.venice.ai/api/v1",
      api_key: {:system, "VENICE_API_KEY"},
      # Venice recommends `reasoning: {enabled: false}` over
      # `reasoning_effort: "none"`, which has limited support.
      compat: %{Omni.Dialects.OpenAICompletions => [thinking_toggle_format: :reasoning_enabled]}
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
