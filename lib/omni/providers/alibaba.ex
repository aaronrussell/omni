defmodule Omni.Providers.Alibaba do
  @moduledoc """
  Provider for the Alibaba Cloud (DashScope) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :alibaba]

  Or load it at runtime:

      Omni.Provider.load([:alibaba])

  Reads the API key from the `DASHSCOPE_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Alibaba,
        api_key: {:system, "MY_DASHSCOPE_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Reasoning

  The `:thinking` option is supported. Effort levels map to token budgets
  for the reasoning step — higher effort allows more reasoning tokens.

  ## Structured output

  The `:output` option is supported. Alibaba doesn't natively support
  JSON Schema constraints, so structured output is achieved via a system
  prompt fallback.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode",
      api_key: {:system, "DASHSCOPE_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/alibaba.json")
  end

  @impl true
  def modify_body(body, _context, _opts) do
    body
    |> normalize_reasoning_effort()
    |> normalize_structured_output()
  end

  defp normalize_reasoning_effort(%{"reasoning_effort" => "none"} = body) do
    body
    |> Map.put("enable_thinking", false)
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(%{"reasoning_effort" => effort} = body) do
    body
    |> Map.put("enable_thinking", true)
    |> Map.put("thinking_budget", effort_to_budget(effort))
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(body), do: body

  defp effort_to_budget("none"), do: 0
  defp effort_to_budget("low"), do: 1024
  defp effort_to_budget("medium"), do: 4096
  defp effort_to_budget("high"), do: 16384
  defp effort_to_budget("xhigh"), do: 24576

  defp normalize_structured_output(
         %{
           "response_format" => %{"type" => "json_schema", "json_schema" => %{"schema" => schema}}
         } =
           body
       ) do
    instruction =
      "Respond with JSON matching this schema:\n```json\n#{JSON.encode!(schema)}\n```"

    body
    |> Map.put("response_format", %{"type" => "json_object"})
    |> append_system_instruction(instruction)
  end

  defp normalize_structured_output(body), do: body

  defp append_system_instruction(
         %{"messages" => [%{"role" => "system"} = system | rest]} = body,
         instruction
       ) do
    system = Map.update!(system, "content", &(&1 <> "\n\n" <> instruction))
    Map.put(body, "messages", [system | rest])
  end

  defp append_system_instruction(%{"messages" => messages} = body, instruction) do
    Map.put(body, "messages", [%{"role" => "system", "content" => instruction} | messages])
  end
end
