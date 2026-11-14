defmodule Omni.Providers.Ollama do
  @moduledoc false

  # The built-in `:ollama` provider: a local Ollama, over its chat API for text
  # and System One for decisions.
  #
  # There is no catalog for a local Ollama, so its models come from config
  # alone, and `models/2` gives the text dialect to any that name none. The two
  # endpoints differ only in path (`/api/chat`, `/v1/systemone`), so `host:`
  # moves both.
  #
  # For Ollama's hosted service, see `Omni.Providers.OllamaCloud`.
  #
  # Users read about it in the "Ollama" section of guides/built-in-providers.md.
  # Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      name: "Ollama",
      auth: :none,
      dialects: %{
        Omni.Dialects.OllamaChat => [base_url: "http://localhost:11434"],
        Omni.Dialects.TypeSafeSystemOne => [base_url: "http://localhost:11434/v1"]
      }
    ]
  end

  # A model that names no dialect speaks Ollama's chat API. One that names
  # its own keeps it, so a decision model names its decision dialect.
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
