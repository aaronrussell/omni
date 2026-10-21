defmodule Omni.Providers.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:openrouter`. Reads the API key from `OPENROUTER_API_KEY`, so
  no configuration is needed if it is set. Override any setting under
  `config :omni, :providers, openrouter: [...]` (see `Omni.Provider`).

  ## Reasoning

  `:thinking` is supported and sent as `reasoning.effort`. Reasoning is sent
  back on later turns of a conversation, as OpenRouter's `reasoning_details`,
  with no extra handling needed.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `thinking_effort_field: "reasoning.effort"`
    * `thinking_replay_field: "reasoning_details"`
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
