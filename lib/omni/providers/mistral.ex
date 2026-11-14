defmodule Omni.Providers.Mistral do
  @moduledoc false

  # The built-in `:mistral` provider: the Mistral AI API, over Chat Completions.
  #
  # - Mistral's own reasoning models take one effort level, `"high"`. The
  #   catalog lists it, so the dialect's usual rounding sends `"high"` for every
  #   level; nothing here does it.
  # - Reasoning is sent back as a thinking chunk at the head of the assistant
  #   message's content, as Mistral recommends (`thinking_replay_format:
  #   :content_chunks`).
  # - PDFs are unsupported: Mistral takes them in a part shape Omni doesn't
  #   send, and the catalog lists no PDF input for its models.
  # - Tool use ids must be 9 characters of a-z, A-Z and 0-9. Mistral's own are,
  #   but it rejects a conversation carrying ids from another provider. Omni
  #   doesn't rewrite them.
  #
  # Users read about it in the "Mistral AI" section of
  # guides/built-in-providers.md. Keep that in step with this module.

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
