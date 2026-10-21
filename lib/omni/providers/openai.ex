defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect.

  Provider id `:openai`. Reads the API key from `OPENAI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, openai: [...]` (see `Omni.Provider`).
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://api.openai.com/v1", api_key: {:system, "OPENAI_API_KEY"}]
  end
end
