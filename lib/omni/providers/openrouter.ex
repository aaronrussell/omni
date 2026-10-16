defmodule Omni.Providers.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Reads the API key from the `OPENROUTER_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        openrouter: [api_key: {:system, "MY_OPENROUTER_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Reasoning

  The `:thinking` option is supported. Reasoning data round-trips
  automatically in multi-turn conversations without any special handling.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://openrouter.ai/api/v1",
      api_key: {:system, "OPENROUTER_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          thinking_effort_field: "reasoning.effort",
          thinking_replay_field: "reasoning_details"
        ]
      }
    ]
  end
end
