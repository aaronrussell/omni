defmodule Omni.Providers.Zai do
  @moduledoc """
  Provider for the Z.ai API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:zai`. Reads the API key from `ZAI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, zai: [...]` (see `Omni.Provider`).

  The catalog lists Z.ai's coding plan, and Zhipu AI's endpoints in China, as
  separate providers (`:zai_coding_plan`, `:zhipuai`,
  `:zhipuai_coding_plan`); `compat: [like: :zai]` gives them these flags.

  ## Reasoning

  `:thinking` is supported. Models that take effort levels get the nearest
  level the model supports; the rest switch thinking on and off with
  `thinking: {type: "enabled" | "disabled"}`. Reasoning from earlier turns
  isn't sent back, which matches Z.ai's default (`clear_thinking: true`).

  ## Structured output

  `:output` is supported. Z.ai has no JSON Schema constraints, so structured
  output uses JSON mode, with the schema described in the system prompt.

  ## Attachments

  Non-image files are sent as `file_url` content parts.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `max_tokens_field: "max_tokens"`
    * `thinking_toggle_format: :thinking_type`
    * `output_format: :json_object`
    * `attachment_format: :file_url`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.z.ai/api/paas/v4",
      api_key: {:system, "ZAI_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          max_tokens_field: "max_tokens",
          thinking_toggle_format: :thinking_type,
          output_format: :json_object,
          attachment_format: :file_url
        ]
      }
    ]
  end
end
