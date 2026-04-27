defmodule Omni.Providers.Zai do
  @moduledoc """
  Provider for the Z.ai API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :zai]

  Or load it at runtime:

      Omni.Provider.load([:zai])

  Reads the API key from the `ZAI_API_KEY` environment variable — no further
  configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Zai,
        api_key: {:system, "MY_ZAI_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Reasoning

  The `:thinking` option is supported. Z.ai exposes no effort granularity —
  all positive levels (`:low` through `:max`) enable reasoning equally.

  ## Structured output

  The `:output` option is supported. Z.ai doesn't natively support JSON
  Schema constraints, so structured output is achieved via a system prompt
  fallback.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.z.ai/api/paas",
      api_key: {:system, "ZAI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/zai.json")
  end

  @impl true
  def build_url(path, opts) do
    opts.base_url <> String.replace(path, "/v1", "/v4")
  end

  @impl true
  def modify_body(body, _context, _opts) do
    body
    |> normalize_reasoning_effort()
    |> normalize_structured_output()
    |> reshape_file_attachments()
  end

  # Z.ai's `clear_thinking` defaults to true — prior-turn `reasoning_content`
  # is dropped on each request.
  defp normalize_reasoning_effort(%{"reasoning_effort" => "none"} = body) do
    body
    |> Map.put("thinking", %{"type" => "disabled"})
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(%{"reasoning_effort" => _} = body) do
    body
    |> Map.put("thinking", %{"type" => "enabled"})
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(body), do: body

  # Z.ai doesn't support `response_format: {type: "json_schema"}`. Instead it
  # needs `{type: "json_object"}` with the schema described in the system prompt.
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

  # Z.ai expects file attachments as `{"type": "file_url", "file_url": ...}`
  # rather than the OpenAI Completions `{"type": "file", "file": ...}` shape.
  defp reshape_file_attachments(%{"messages" => messages} = body) do
    Map.put(body, "messages", Enum.map(messages, &reshape_message_content/1))
  end

  defp reshape_file_attachments(body), do: body

  defp reshape_message_content(%{"role" => "user", "content" => content} = msg)
       when is_list(content) do
    Map.put(msg, "content", Enum.map(content, &reshape_block/1))
  end

  defp reshape_message_content(msg), do: msg

  defp reshape_block(%{"type" => "file", "file" => %{"file_data" => data}}) do
    %{"type" => "file_url", "file_url" => %{"url" => data}}
  end

  defp reshape_block(block), do: block
end
