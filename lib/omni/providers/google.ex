defmodule Omni.Providers.Google do
  @moduledoc """
  Provider for the Google Gemini API, using the `Omni.Dialects.GoogleGemini`
  dialect.

  Loaded by default. Reads the API key from the `GEMINI_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        google: [api_key: {:system, "MY_GEMINI_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: {:system, "GEMINI_API_KEY"}
    ]
  end
end
