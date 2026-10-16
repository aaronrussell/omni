defmodule Omni.Providers.Zai do
  @moduledoc """
  Provider for the Z.ai API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Reads the API key from the `ZAI_API_KEY` environment variable — no further
  configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        zai: [api_key: {:system, "MY_ZAI_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Reasoning

  The `:thinking` option is supported. Models that take effort levels get
  the nearest level the model supports; the rest switch thinking on and off
  with `thinking: {type: "enabled" | "disabled"}`. Z.ai's `clear_thinking`
  defaults to true, so earlier turns' reasoning is not sent back.

  ## Structured output

  The `:output` option is supported. Z.ai doesn't natively support JSON
  Schema constraints, so structured output uses JSON mode with the schema
  described in the system prompt.

  ## Attachments

  File attachments are sent as `file_url` content parts.
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
