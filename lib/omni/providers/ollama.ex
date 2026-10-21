defmodule Omni.Providers.Ollama do
  @moduledoc """
  Provider for a local Ollama instance, using the `Omni.Dialects.OllamaChat`
  dialect.

  Provider id `:ollama`. Talks to `http://localhost:11434` with no
  authentication. For Ollama's hosted service, use `Omni.Providers.OllamaCloud`.

  ## Models

  A local instance's models are whatever you have pulled, so there is no
  catalog to load them from. List them in config, each as a model id or a
  keyword list of `Omni.Model.new/1` attributes (only `:id` is required):

      config :omni, :providers,
        ollama: [
          models: [
            "mistral:7b",
            [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
            [id: "qwen3.5:4b", name: "Qwen 3.5 4B", context_size: 32_768, thinking: true]
          ]
        ]

  Without this config the provider loads no models.

  ## Configuration

  For another host or port, set `:base_url`:

      config :omni, :providers,
        ollama: [base_url: "http://192.168.1.10:11434"]

  Requests are sent without credentials. For an instance behind an
  authenticating proxy, send a key as a Bearer token:

      config :omni, :providers,
        ollama: [auth: :bearer, api_key: {:system, "OLLAMA_PROXY_KEY"}]

  ## Limitations

  Only base64-encoded images are supported. URL image attachments
  (`{:url, url}`) are skipped, because Ollama's API has no way to take an
  image by URL.
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
