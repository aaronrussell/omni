defmodule Omni.Providers.Zai do
  @moduledoc false

  # The built-in `:zai` provider: the Z.ai API, over Chat Completions.
  #
  # - Z.ai has no JSON Schema constraints, hence `output_format: :json_object`.
  # - By default (`clear_thinking: true`, which Omni leaves alone) Z.ai uses
  #   replayed reasoning only within a tool loop, and drops reasoning from
  #   before the latest user message.
  #
  # Users read about it in the "Z.ai" section of guides/built-in-providers.md.
  # Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "ZAI_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.z.ai/api/paas/v4",
          compat: [
            max_tokens_field: "max_tokens",
            thinking_toggle_format: :thinking_type,
            thinking_replay_format: :reasoning_content,
            output_format: :json_object,
            attachment_format: :file_url
          ]
        ]
      }
    ]
  end
end
