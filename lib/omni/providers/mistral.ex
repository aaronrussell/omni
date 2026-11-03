defmodule Omni.Providers.Mistral do
  @moduledoc """
  Provider for the Mistral AI API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:mistral`. Reads the API key from `MISTRAL_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, mistral: [...]` (see `Omni.Provider`).

  ## Reasoning

  `:thinking` is supported and sent as `reasoning_effort`. Mistral's own
  reasoning models take a single level, `"high"`, so every level becomes
  `"high"`; `thinking: false` sends `"none"`. Other models Mistral serves
  (such as GLM) take their own levels.

  Reasoning is sent back on later turns of a conversation as a thinking
  chunk at the head of the assistant message's content, as Mistral
  recommends.

  ## Limitations

  PDF attachments are not supported: Mistral takes them in a part shape
  Omni doesn't send yet, and the catalog lists no PDF input for its models.

  Tool call ids must be 9 characters of a-z, A-Z and 0-9. Mistral's own ids
  are, but a conversation carrying tool calls from another provider is
  rejected.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `max_tokens_field: "max_tokens"`
    * `thinking_replay_format: :content_chunks`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "MISTRAL_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.mistral.ai/v1",
          compat: [
            # Mistral has no `max_completion_tokens`.
            max_tokens_field: "max_tokens",
            thinking_replay_format: :content_chunks
          ]
        ]
      }
    ]
  end
end
