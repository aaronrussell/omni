defmodule Omni.Providers.Google do
  @moduledoc """
  Provider for the Google Gemini API, using the `Omni.Dialects.GoogleGemini`
  dialect.

  Loaded by default. Reads the API key from the `GEMINI_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Google,
        api_key: {:system, "MY_GEMINI_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.
  """

  use Omni.Provider, dialect: Omni.Dialects.GoogleGemini

  @impl true
  def config do
    %{
      base_url: "https://generativelanguage.googleapis.com",
      auth_header: "x-goog-api-key",
      api_key: {:system, "GEMINI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/google.json")
  end
end
