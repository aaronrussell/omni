defmodule Omni.Providers.Alibaba do
  @moduledoc false

  # Provider for the Alibaba Cloud (DashScope) API, using the
  # `Omni.Dialects.OpenAICompletions` dialect.
  #
  # Regions:
  #
  # Defaults to the International (Singapore) endpoint,
  # `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`. Every region
  # serves the same `/compatible-mode/v1` path, so to use another, set `:host`:
  #
  #     config :omni, :providers,
  #       alibaba: [host: "https://dashscope-us.aliyuncs.com"]
  #
  # | Region                    | Host                                                  |
  # |---------------------------|-------------------------------------------------------|
  # | International (Singapore) | `https://dashscope-intl.aliyuncs.com`                 |
  # | US (Virginia)             | `https://dashscope-us.aliyuncs.com`                   |
  # | Germany (Frankfurt)       | `https://{WorkspaceId}.eu-central-1.maas.aliyuncs.com` |
  # | China (Beijing)           | `https://dashscope.aliyuncs.com`                      |
  # | China (Hong Kong)         | `https://cn-hongkong.dashscope.aliyuncs.com`          |
  #
  # The catalog also lists the Beijing endpoint as its own provider,
  # `:alibaba_cn`, which takes these flags with
  # `dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :alibaba]]}`.
  #
  # Reasoning:
  #
  # `:thinking` is supported. Most models switch thinking on with
  # `enable_thinking` and take a token budget, which effort levels map to:
  # higher effort allows more reasoning tokens. Models that take effort levels
  # get the nearest level the model supports. Earlier reasoning is sent back in
  # the `reasoning_content` field of assistant messages.
  #
  # Structured output:
  #
  # `:output` is supported. Alibaba has no JSON Schema constraints, so
  # structured output uses JSON mode, with the schema described in the system
  # prompt.
  #
  # What users are told is the "Alibaba" section of
  # guides/built-in-providers.md; keep it in step with this module.

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
