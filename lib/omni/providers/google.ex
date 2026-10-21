defmodule Omni.Providers.Google do
  @moduledoc """
  Provider for the Google Gemini API, using the `Omni.Dialects.GoogleGemini`
  dialect.

  Provider id `:google`. Reads the API key from `GEMINI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, google: [...]` (see `Omni.Provider`).
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
