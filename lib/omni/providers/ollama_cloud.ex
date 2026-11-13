defmodule Omni.Providers.OllamaCloud do
  @moduledoc false

  # Provider for Ollama's hosted cloud service, using the
  # `Omni.Dialects.OllamaChat` dialect.
  #
  # For a local Ollama instance, use `Omni.Providers.Ollama`.
  #
  # The catalog describes Ollama's OpenAI-compatible endpoint. Omni uses the
  # native chat API at `https://ollama.com` instead, so every text model (and
  # every config model that names no dialect) is given the Ollama Chat dialect
  # when the provider loads, in the module's `models/2`. That
  # runs after config `models:` entries are merged, so a text dialect set in
  # config is replaced too. Decision-only models are left alone.
  #
  # Limitations:
  #
  # Only base64-encoded images are supported. URL image attachments
  # (`{:url, url}`) are skipped, because Ollama's API has no way to take an
  # image by URL.
  #
  # Structured output isn't enforced. Ollama Cloud accepts the `:output` schema
  # (sent as `format`) but doesn't constrain generation to it, so models may
  # answer in prose and fail validation. Local Ollama enforces it.
  #
  # What users are told is the "Ollama Cloud" section of
  # guides/built-in-providers.md; keep it in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "OLLAMA_API_KEY"},
      dialects: %{Omni.Dialects.OllamaChat => [base_url: "https://ollama.com"]}
    ]
  end

  # Catalog data describes Ollama's OpenAI-compatible endpoint; Omni uses the
  # native chat API, so every text model is re-stamped with its dialect. A
  # config model naming no dialect gets it too; decision-only models don't.
  @impl true
  def models(models, _provider) do
    Enum.map(models, fn model ->
      if Model.capability?(model, :text) or model.dialects == %{},
        do: %{model | dialects: Map.put(model.dialects, :text, Omni.Dialects.OllamaChat)},
        else: model
    end)
  end
end
