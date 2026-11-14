defmodule Omni.Providers.OllamaCloud do
  @moduledoc false

  # The built-in `:ollama_cloud` provider: Ollama's hosted service, over its
  # chat API.
  #
  # The catalog describes Ollama's OpenAI-compatible endpoint
  # (`https://ollama.com/v1`). Omni uses the native chat API, so `models/2`
  # moves every text model to it.
  #
  # Ollama Cloud accepts the `:output` schema (sent as `format`) but doesn't
  # constrain generation to it. A local Ollama does.
  #
  # For a local Ollama, see `Omni.Providers.Ollama`.
  #
  # Users read about it in the "Ollama Cloud" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "OLLAMA_API_KEY"},
      dialects: %{Omni.Dialects.OllamaChat => [base_url: "https://ollama.com"]}
    ]
  end

  # Gives every text model the chat dialect, and every config model that
  # names no dialect. Decision-only models are left alone. This runs after
  # config `models:` entries are merged, so a text dialect set in config is
  # replaced too.
  @impl true
  def models(models, _provider) do
    Enum.map(models, fn model ->
      if Model.capability?(model, :text) or model.dialects == %{},
        do: %{model | dialects: Map.put(model.dialects, :text, Omni.Dialects.OllamaChat)},
        else: model
    end)
  end
end
