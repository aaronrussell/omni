defmodule Omni.Providers.Google do
  @moduledoc false

  # The built-in `:google` provider: the Gemini API, over `generateContent`.
  #
  # Users read about it in the "Google" section of guides/built-in-providers.md.
  # Keep that in step with this module.

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
