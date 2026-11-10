defmodule Omni.Providers.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API, using the `Omni.Dialects.OpenAICompletions`
  dialect for text and `Omni.Dialects.TypeSafeSystemOne` for decisions.

  Provider id `:openrouter`. Reads the API key from `OPENROUTER_API_KEY`, so
  no configuration is needed if it is set. Override any setting under
  `config :omni, :providers, openrouter: [...]` (see `Omni.Provider`).

  ## Decisions

  Decision models (`typesafe/jev-1.14`, `liquid/d1` and others) are sent to
  `/api/v1/systemone`, OpenRouter's System One route. OpenRouter also
  serves the same wire format at `/api/alpha/decisions`, which it marks as
  subject to change.

  ## Reasoning

  `:thinking` is supported and sent as `reasoning.effort`. Reasoning is sent
  back on later turns of a conversation, as OpenRouter's `reasoning_details`,
  with no extra handling needed.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `thinking_effort_field: "reasoning.effort"`
    * `thinking_replay_format: :reasoning_details`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "OPENROUTER_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://openrouter.ai/api/v1",
          compat: [
            thinking_effort_field: "reasoning.effort",
            thinking_replay_format: :reasoning_details
          ]
        ],
        # Decision models, at /api/v1/systemone. Set here because llm_db
        # describes them at OpenRouter's origin, for its alpha route.
        Omni.Dialects.TypeSafeSystemOne => [base_url: "https://openrouter.ai/api/v1"]
      }
    ]
  end
end
