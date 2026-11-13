defmodule Omni.Providers.Zai do
  @moduledoc false

  # Provider for the Z.ai API, using the `Omni.Dialects.OpenAICompletions`
  # dialect.
  #
  # The catalog lists Z.ai's coding plan, and Zhipu AI's endpoints in China, as
  # separate providers (`:zai_coding_plan`, `:zhipuai`,
  # `:zhipuai_coding_plan`), which take these flags with
  # `dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :zai]]}`.
  #
  # Reasoning:
  #
  # `:thinking` is supported. Models that take effort levels get the nearest
  # level the model supports; the rest switch thinking on and off with
  # `thinking: {type: "enabled" | "disabled"}`. Earlier reasoning is sent back
  # in the `reasoning_content` field of assistant messages. By default
  # (`clear_thinking: true`) Z.ai uses it only within a tool loop, and drops
  # reasoning from before the latest user message.
  #
  # Structured output:
  #
  # `:output` is supported. Z.ai has no JSON Schema constraints, so structured
  # output uses JSON mode, with the schema described in the system prompt.
  #
  # Attachments:
  #
  # Non-image files are sent as `file_url` content parts.
  #
  # What users are told is the "Z.ai" section of guides/built-in-providers.md;
  # keep it in step with this module.

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
