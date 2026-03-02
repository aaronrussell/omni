defmodule Omni.Providers.Google do
  @moduledoc """
  Provider for the Google Gemini API, using the `Omni.Dialects.GoogleGemini`
  dialect.
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
