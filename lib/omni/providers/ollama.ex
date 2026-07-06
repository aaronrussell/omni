defmodule Omni.Providers.Ollama do
  @moduledoc """
  Provider for a local Ollama instance, using the `Omni.Dialects.OllamaChat`
  dialect.

  Talks to `http://localhost:11434` with no authentication. For Ollama's
  hosted cloud service, use `Omni.Providers.OllamaCloud` instead.

  ## Models

  A local instance's models are whatever you have pulled, so there is no
  catalog to load from — list the models you have locally. Each entry can be
  a string (just the model ID) or a keyword list for full control:

      config :omni, Omni.Providers.Ollama,
        models: [
          "mistral:7b",
          [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
          [id: "qwen3.5:4b", name: "Qwen 3.5 4B", context_size: 32_768, reasoning: true]
        ]

  String entries use the ID as the display name with default values for all
  other fields. Keyword entries accept any field from `Omni.Model.new/1` —
  only `:id` is required, everything else has sensible defaults.

  Without this config the provider loads no models.

  ## Configuration

  Override the base URL for a non-default host or port:

      config :omni, Omni.Providers.Ollama,
        base_url: "http://192.168.1.10:11434"

  ## Limitations

  - **Image attachments**: Only base64-encoded images are supported. URL-based
    image attachments (`{:url, url}`) are silently skipped because Ollama's API
    has no URL image input mechanism.
  """

  use Omni.Provider, id: :ollama, dialect: Omni.Dialects.OllamaChat

  @impl true
  def config do
    %{
      base_url: "http://localhost:11434",
      api_key: nil
    }
  end

  @impl true
  def models do
    :omni
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:models, [])
    |> Enum.map(&build_model/1)
  end

  @impl true
  def authenticate(req, %{api_key: nil}), do: {:ok, req}
  def authenticate(req, opts), do: super(req, opts)

  defp build_model(id) when is_binary(id) do
    build_model(id: id)
  end

  defp build_model(attrs) when is_list(attrs) do
    [name: attrs[:id]]
    |> Keyword.merge(attrs)
    |> Keyword.merge(provider: __MODULE__, dialect: dialect())
    |> Omni.Model.new()
  end
end
