defmodule Omni.Providers.OllamaCloud do
  @moduledoc """
  Provider for Ollama's hosted cloud service, using the
  `Omni.Dialects.OllamaChat` dialect.

  Reads the API key from the `OLLAMA_API_KEY` environment variable — no
  further configuration is needed if the variable is set. For a local
  Ollama instance, use `Omni.Providers.Ollama` instead.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.OllamaCloud,
        api_key: {:system, "MY_OLLAMA_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Limitations

  - **Image attachments**: Only base64-encoded images are supported. URL-based
    image attachments (`{:url, url}`) are silently skipped because Ollama's API
    has no URL image input mechanism.
  """

  use Omni.Provider, id: :ollama_cloud, dialect: Omni.Dialects.OllamaChat

  @impl true
  def config do
    %{
      base_url: "https://ollama.com",
      api_key: {:system, "OLLAMA_API_KEY"}
    }
  end

  @impl true
  def models do
    # Catalog data reports Ollama's OpenAI-compatible endpoint; Omni prefers
    # the native chat API, so re-apply the declared dialect.
    __MODULE__
    |> Omni.Provider.load_models()
    |> Enum.map(&%{&1 | dialect: dialect()})
  end
end
