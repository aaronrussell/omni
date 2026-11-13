defmodule Omni.Providers.Together do
  @moduledoc false

  # Provider for the Together AI API, using the `Omni.Dialects.OpenAICompletions`
  # dialect.
  #
  # For US-only inference, set `host: "https://us-api.together.ai"`.
  #
  # Reasoning:
  #
  # `:thinking` is supported. Models that take effort levels get the nearest
  # level the model supports; the rest switch thinking on and off with
  # `reasoning: {enabled: true | false}`. Models that list effort values but no
  # toggle (such as gpt-oss) can't be switched off, so `thinking: false` sends
  # nothing to them.
  #
  # Earlier reasoning is sent back in the `reasoning` field of assistant
  # messages, the field it arrives in.
  #
  # Limitations:
  #
  # DeepSeek V4 Pro keeps reasoning with `thinking: false`: it ignores
  # `reasoning: {enabled: false}`, though the catalog lists a toggle.
  #
  # What users are told is the "Together AI" section of
  # guides/built-in-providers.md; keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "TOGETHER_API_KEY"},
      # No `max_completion_tokens` in Together's API.
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.together.ai/v1",
          compat: [
            max_tokens_field: "max_tokens",
            # `reasoning_effort` takes no "none"; hybrid models switch with
            # `reasoning: {enabled: ...}`.
            thinking_toggle_format: :reasoning_enabled,
            # Reasoning arrives in `reasoning`; Together asks for it back there.
            thinking_replay_format: :reasoning,
            # Caching is automatic; there is no retention field.
            omit: [:cache]
          ]
        ]
      }
    ]
  end
end
