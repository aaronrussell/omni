defmodule Omni.Providers.OllamaCloud do
  @moduledoc """
  Provider for Ollama's hosted cloud service, using the
  `Omni.Dialects.OllamaChat` dialect.

  Reads the API key from the `OLLAMA_API_KEY` environment variable — no
  further configuration is needed if the variable is set. For a local
  Ollama instance, use the `:ollama` provider instead.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        ollama_cloud: [api_key: {:system, "MY_OLLAMA_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Limitations

  - **Image attachments**: Only base64-encoded images are supported. URL-based
    image attachments (`{:url, url}`) are silently skipped because Ollama's API
    has no URL image input mechanism.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://ollama.com",
      api_key: {:system, "OLLAMA_API_KEY"},
      dialects: %{text: Omni.Dialects.OllamaChat}
    ]
  end

  # Catalog data describes Ollama's OpenAI-compatible endpoint; Omni uses the
  # native chat API, so every model is re-stamped with its dialect.
  @impl true
  def models(models, _provider) do
    Enum.map(models, &%{&1 | dialects: Map.put(&1.dialects, :text, Omni.Dialects.OllamaChat)})
  end
end
