defmodule Omni.Providers.Together do
  @moduledoc false

  # The built-in `:togetherai` provider: the Together AI API, over Chat
  # Completions.
  #
  # DeepSeek V4 Pro keeps reasoning with `thinking: false`: it ignores
  # `reasoning: {enabled: false}`, though the catalog lists a toggle. Nothing
  # here works around it.
  #
  # Users read about it in the "Together AI" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "TOGETHER_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.together.ai/v1",
          compat: [
            # Together has no `max_completion_tokens`.
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
