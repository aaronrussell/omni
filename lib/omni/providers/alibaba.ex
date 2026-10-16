defmodule Omni.Providers.Alibaba do
  @moduledoc """
  Provider for the Alibaba Cloud (DashScope) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `DASHSCOPE_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        alibaba: [api_key: {:system, "MY_DASHSCOPE_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Regions

  Defaults to the International (Singapore) endpoint. To use a different
  region, override `:base_url`:

      config :omni, :providers,
        alibaba: [base_url: "https://dashscope-us.aliyuncs.com/compatible-mode/v1"]

  Available regions:

  | Region                    | Base URL                                                                  |
  |---------------------------|---------------------------------------------------------------------------|
  | International (Singapore) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`                  |
  | US (Virginia)             | `https://dashscope-us.aliyuncs.com/compatible-mode/v1`                    |
  | Germany (Frankfurt)       | `https://{WorkspaceId}.eu-central-1.maas.aliyuncs.com/compatible-mode/v1` |
  | China (Beijing)           | `https://dashscope.aliyuncs.com/compatible-mode/v1`                       |
  | China (Hong Kong)         | `https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1`           |

  ## Reasoning

  The `:thinking` option is supported. Most models switch thinking on with
  `enable_thinking` and take a token budget, which effort levels map to —
  higher effort allows more reasoning tokens. Models that take effort levels
  get the nearest level the model supports.

  ## Structured output

  The `:output` option is supported. Alibaba doesn't natively support
  JSON Schema constraints, so structured output uses JSON mode with the
  schema described in the system prompt.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      api_key: {:system, "DASHSCOPE_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          thinking_toggle_format: :enable_thinking,
          thinking_budget_field: "thinking_budget",
          output_format: :json_object
        ]
      }
    ]
  end
end
