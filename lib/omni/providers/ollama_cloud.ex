defmodule Omni.Providers.OllamaCloud do
  @moduledoc """
  Provider for Ollama's hosted cloud service, using the
  `Omni.Dialects.OllamaChat` dialect.

  Provider id `:ollama_cloud`. Reads the API key from `OLLAMA_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, ollama_cloud: [...]` (see `Omni.Provider`). For
  a local Ollama instance, use `Omni.Providers.Ollama`.

  The catalog describes Ollama's OpenAI-compatible endpoint. Omni uses the
  native chat API at `https://ollama.com` instead, so every model is given
  the Ollama Chat dialect when the provider loads, in the module's
  `c:Omni.Provider.models/2`. That runs after config `models:` entries are
  merged, so a `:dialects` set in config is replaced too.

  ## Limitations

  Only base64-encoded images are supported. URL image attachments
  (`{:url, url}`) are skipped, because Ollama's API has no way to take an
  image by URL.

  Structured output isn't enforced. Ollama Cloud accepts the `:output` schema
  (sent as `format`) but doesn't constrain generation to it, so models may
  answer in prose and fail validation. Local Ollama enforces it.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "OLLAMA_API_KEY"},
      dialects: %{Omni.Dialects.OllamaChat => [base_url: "https://ollama.com"]}
    ]
  end

  # Catalog data describes Ollama's OpenAI-compatible endpoint; Omni uses the
  # native chat API, so every model is re-stamped with its dialect.
  @impl true
  def models(models, _provider) do
    Enum.map(models, &%{&1 | dialects: Map.put(&1.dialects, :text, Omni.Dialects.OllamaChat)})
  end
end
