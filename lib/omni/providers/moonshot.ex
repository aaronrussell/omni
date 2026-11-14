defmodule Omni.Providers.Moonshot do
  @moduledoc false

  # The built-in `:moonshotai` provider: the Moonshot AI (Kimi) API, over Chat
  # Completions.
  #
  # Kimi K2.6 ignores the `:output` schema while thinking, which is on by
  # default. Nothing here works around it: the guide tells users to pass
  # `thinking: false`.
  #
  # Users read about it in the "Moonshot AI" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "MOONSHOT_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.moonshot.ai/v1",
          compat: [
            thinking_toggle_format: :thinking_type,
            thinking_replay_format: :reasoning_content
          ]
        ]
      }
    ]
  end
end
