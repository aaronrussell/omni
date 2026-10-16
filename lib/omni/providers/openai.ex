defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect.

  Loaded by default. Reads the API key from the `OPENAI_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        openai: [api_key: {:system, "MY_OPENAI_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://api.openai.com/v1", api_key: {:system, "OPENAI_API_KEY"}]
  end
end
