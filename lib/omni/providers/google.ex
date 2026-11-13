defmodule Omni.Providers.Google do
  @moduledoc false

  # Provider for the Google Gemini API, using the `Omni.Dialects.GoogleGenerateContent`
  # dialect.
  #
  # What users are told is the "Google" section of guides/built-in-providers.md;
  # keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "GEMINI_API_KEY"},
      dialects: %{
        Omni.Dialects.GoogleGenerateContent => [
          base_url: "https://generativelanguage.googleapis.com/v1beta"
        ]
      }
    ]
  end
end
