defmodule Omni.Providers.Moonshot do
  @moduledoc """
  Provider for the Moonshot AI (Kimi) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `MOONSHOT_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        moonshotai: [api_key: {:system, "MY_MOONSHOT_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Reasoning

  The `:thinking` option is supported. Models that take effort levels get
  the nearest level the model supports; the rest switch thinking on and off
  with `thinking: {type: "enabled" | "disabled"}`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.moonshot.ai/v1",
      api_key: {:system, "MOONSHOT_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          thinking_toggle_format: :thinking_type
        ]
      }
    ]
  end
end
