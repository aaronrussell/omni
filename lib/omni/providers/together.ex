defmodule Omni.Providers.Together do
  @moduledoc """
  Provider for the Together AI API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:togetherai`. Reads the API key from `TOGETHER_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, togetherai: [...]` (see `Omni.Provider`). For
  US-only inference, set `base_url: "https://us-api.together.ai/v1"`.

  ## Reasoning

  `:thinking` is supported. Models that take effort levels get the nearest
  level the model supports; the rest switch thinking on and off with
  `reasoning: {enabled: true | false}`. Models that list effort values but no
  toggle (such as gpt-oss) can't be switched off, so `thinking: false` sends
  nothing to them.

  Earlier reasoning is not sent back on later turns.

  ## Limitations

  DeepSeek V4 Pro keeps reasoning with `thinking: false`: it ignores
  `reasoning: {enabled: false}`, though the catalog lists a toggle.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `max_tokens_field: "max_tokens"`
    * `thinking_toggle_format: :reasoning_enabled`
    * `omit: [:cache]`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.together.ai/v1",
      api_key: {:system, "TOGETHER_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          # No `max_completion_tokens` in Together's API.
          max_tokens_field: "max_tokens",
          # `reasoning_effort` takes no "none"; hybrid models switch with
          # `reasoning: {enabled: ...}`.
          thinking_toggle_format: :reasoning_enabled,
          # Caching is automatic; there is no retention field.
          omit: [:cache]
        ]
      }
    ]
  end
end
