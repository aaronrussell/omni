defmodule Omni.Providers.Ollama do
  @moduledoc """
  Provider for a local Ollama instance, using the `Omni.Dialects.OllamaChat`
  dialect.

  Talks to `http://localhost:11434` with no authentication. For Ollama's
  hosted cloud service, use the `:ollama_cloud` provider instead.

  ## Models

  A local instance's models are whatever you have pulled, so there is no
  catalog to load from — list the models you have locally. Each entry can be
  a string (just the model ID) or a keyword list for full control:

      config :omni, :providers,
        ollama: [
          models: [
            "mistral:7b",
            [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
            [id: "qwen3.5:4b", name: "Qwen 3.5 4B", context_size: 32_768, reasoning: true]
          ]
        ]

  String entries use the ID as the display name with default values for all
  other fields. Keyword entries accept any field from `Omni.Model.new/1` —
  only `:id` is required, everything else has sensible defaults.

  Without this config the provider loads no models.

  ## Configuration

  Override the base URL for a non-default host or port:

      config :omni, :providers,
        ollama: [base_url: "http://192.168.1.10:11434"]

  Requests are sent without credentials. For an instance behind an
  authenticating proxy, send the key as a Bearer token:

      config :omni, :providers,
        ollama: [auth: :bearer, api_key: {:system, "OLLAMA_PROXY_KEY"}]

  ## Limitations

  - **Image attachments**: Only base64-encoded images are supported. URL-based
    image attachments (`{:url, url}`) are silently skipped because Ollama's API
    has no URL image input mechanism.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "http://localhost:11434",
      auth: :none,
      dialects: %{text: Omni.Dialects.OllamaChat}
    ]
  end
end
