defmodule Omni.Providers.Ollama do
  @moduledoc """
  Provider for the Ollama API, using the `Omni.Dialects.OllamaChat` dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :ollama]

  Or load it at runtime:

      Omni.Provider.load([:ollama])

  ## Configuration

  Defaults to a local Ollama instance at `http://localhost:11434` with no
  authentication. For cloud-hosted Ollama instances that require an API key:

      config :omni, Omni.Providers.Ollama,
        base_url: "https://ollama.com",
        api_key: {:system, "OLLAMA_API_KEY"}

  ## Models

  By default, models are loaded from `priv/models/ollama-cloud.json`. For local
  Ollama instances, override with a list of models matching what you have
  pulled locally. Each entry can be a string (just the model ID) or a keyword
  list for full control:

      config :omni, Omni.Providers.Ollama,
        models: [
          "mistral:7b",
          [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
          [id: "qwen3.5:4b", name: "Qwen 3.5 4B", context_size: 32_768, reasoning: true]
        ]

  String entries use the ID as the display name with default values for all
  other fields. Keyword entries accept any field from `Omni.Model.new/1` —
  only `:id` is required, everything else has sensible defaults.
  """

  use Omni.Provider, dialect: Omni.Dialects.OllamaChat

  @impl true
  def config do
    %{
      base_url: "http://localhost:11434",
      api_key: nil
    }
  end

  @impl true
  def models do
    case Application.get_env(:omni, __MODULE__, [])[:models] do
      nil ->
        Omni.Provider.load_models(__MODULE__, "priv/models/ollama-cloud.json")

      model_ids when is_list(model_ids) ->
        Enum.map(model_ids, &build_model/1)
    end
  end

  @impl true
  def authenticate(req, %{api_key: nil}), do: {:ok, req}
  def authenticate(req, opts), do: super(req, opts)

  defp build_model(id) when is_binary(id) do
    build_model(id: id)
  end

  defp build_model(attrs) when is_list(attrs) do
    defaults = [name: attrs[:id], provider: __MODULE__, dialect: dialect()]

    defaults
    |> Keyword.merge(attrs)
    |> Omni.Model.new()
  end
end
