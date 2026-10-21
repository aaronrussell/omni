defmodule Omni.Providers.Alibaba do
  @moduledoc """
  Provider for the Alibaba Cloud (DashScope) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Provider id `:alibaba`. Reads the API key from `DASHSCOPE_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, alibaba: [...]` (see `Omni.Provider`).

  ## Regions

  Defaults to the International (Singapore) endpoint. To use another region,
  set `:base_url`:

      config :omni, :providers,
        alibaba: [base_url: "https://dashscope-us.aliyuncs.com/compatible-mode/v1"]

  | Region                    | Base URL                                                                  |
  |---------------------------|---------------------------------------------------------------------------|
  | International (Singapore) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`                  |
  | US (Virginia)             | `https://dashscope-us.aliyuncs.com/compatible-mode/v1`                    |
  | Germany (Frankfurt)       | `https://{WorkspaceId}.eu-central-1.maas.aliyuncs.com/compatible-mode/v1` |
  | China (Beijing)           | `https://dashscope.aliyuncs.com/compatible-mode/v1`                       |
  | China (Hong Kong)         | `https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1`           |

  The catalog also lists the Beijing endpoint as its own provider,
  `:alibaba_cn`; `compat: [like: :alibaba]` gives it these flags.

  ## Reasoning

  `:thinking` is supported. Most models switch thinking on with
  `enable_thinking` and take a token budget, which effort levels map to:
  higher effort allows more reasoning tokens. Models that take effort levels
  get the nearest level the model supports.

  ## Structured output

  `:output` is supported. Alibaba has no JSON Schema constraints, so
  structured output uses JSON mode, with the schema described in the system
  prompt.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `thinking_toggle_format: :enable_thinking`
    * `thinking_budget_field: "thinking_budget"`
    * `output_format: :json_object`
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
