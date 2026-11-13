defmodule Omni.Providers.Ollama do
  @moduledoc false

  # Provider for a local Ollama instance, using the `Omni.Dialects.OllamaChat`
  # dialect for text and `Omni.Dialects.TypeSafeSystemOne` for decisions.
  #
  # Talks to `http://localhost:11434` with no authentication: chat at
  # `/api/chat`, decisions at `/v1/systemone`. For Ollama's hosted service, use
  # `Omni.Providers.OllamaCloud`.
  #
  # Models:
  #
  # A local instance's models are whatever you have pulled, so there is no
  # catalog to load them from. List them in config, each as a model id or a
  # keyword list of `Omni.Model.new/1` attributes (only `:id` is required):
  #
  #     config :omni, :providers,
  #       ollama: [
  #         models: [
  #           "mistral:7b",
  #           [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
  #           [id: "qwen3.5:4b", name: "Qwen 3.5 4B", context_size: 32_768, thinking: true]
  #         ]
  #       ]
  #
  # Models listed this way speak `Omni.Dialects.OllamaChat`; an entry that
  # names its own `:dialects` keeps them. A decision model names its decision
  # dialect, and a model that serves both names both:
  #
  #     config :omni, :providers,
  #       ollama: [
  #         models: [
  #           [id: "clef", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}],
  #           [
  #             id: "both",
  #             dialects: %{text: Omni.Dialects.OllamaChat, decision: Omni.Dialects.TypeSafeSystemOne}
  #           ]
  #         ]
  #       ]
  #
  # Without this config the provider loads no models.
  #
  # Configuration:
  #
  # For another host or port, set `:host`, which moves both endpoints:
  #
  #     config :omni, :providers,
  #       ollama: [host: "http://192.168.1.10:11434"]
  #
  # Requests are sent without credentials. For an instance behind an
  # authenticating proxy, send a key as a Bearer token:
  #
  #     config :omni, :providers,
  #       ollama: [auth: :bearer, api_key: {:system, "OLLAMA_PROXY_KEY"}]
  #
  # Limitations:
  #
  # Only base64-encoded images are supported. URL image attachments
  # (`{:url, url}`) are skipped, because Ollama's API has no way to take an
  # image by URL.
  #
  # What users are told is the "Ollama" section of guides/built-in-providers.md;
  # keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      auth: :none,
      dialects: %{
        Omni.Dialects.OllamaChat => [base_url: "http://localhost:11434"],
        Omni.Dialects.TypeSafeSystemOne => [base_url: "http://localhost:11434/v1"]
      }
    ]
  end

  # Models listed in config by id alone speak Ollama's chat API. A model
  # that names its own dialect keeps it.
  @impl true
  def models(models, _provider) do
    Enum.map(models, fn
      %{dialects: dialects} = model when dialects == %{} ->
        %{model | dialects: %{text: Omni.Dialects.OllamaChat}}

      model ->
        model
    end)
  end
end
