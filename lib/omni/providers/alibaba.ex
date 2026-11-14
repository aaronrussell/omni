defmodule Omni.Providers.Alibaba do
  @moduledoc false

  # The built-in `:alibaba` provider: Alibaba Cloud's DashScope API, over Chat
  # Completions.
  #
  # The default URL is the International (Singapore) region. Every region serves
  # the same `/compatible-mode/v1` path, so `host:` alone moves between them.
  # The guide lists the hosts.
  #
  # Alibaba has no JSON Schema constraints, hence `output_format: :json_object`.
  #
  # Users read about it in the "Alibaba" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "DASHSCOPE_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          compat: [
            thinking_toggle_format: :enable_thinking,
            thinking_budget_field: "thinking_budget",
            thinking_replay_format: :reasoning_content,
            output_format: :json_object
          ]
        ]
      }
    ]
  end
end
