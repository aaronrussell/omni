defmodule Omni.Dialects.GoogleGemini do
  @moduledoc """
  Dialect for the Google Gemini API.

  Translates Omni types to the Google Gemini wire format and parses
  streaming SSE events into normalized delta tuples.

  ## Structural differences from other dialects

  - The model ID is embedded in the URL path (no `"model"` key in body)
  - Streaming is triggered by the endpoint + `?alt=sse` (no `"stream"` key)
  - Assistant role maps to `"model"` (not `"assistant"`)
  - System prompt uses `"systemInstruction"` with a `"parts"` array
  - Options go in `"generationConfig"` wrapper
  - Tools use `"functionDeclarations"` wrapper
  - Function calls are sent complete (not streamed as JSON fragments)

  ## Known limitations

  - No `:start` event emitted (Google has no equivalent of Anthropic's
    `message_start`)
  - Google may bundle text + finishReason + usage in a single SSE event;
    content is prioritized, which may cause `:done`/`:usage` signals to be
    lost from bundled events
  - No `:tool_use_delta` events — Google sends function call args complete
    (as a map), not as streamed JSON fragments
  - Cache option is a no-op (Google uses server-side caching, incompatible
    model)
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @impl true
  def option_schema, do: %{}

  @impl true
  def build_path(%Model{id: model_id}) do
    "/v1beta/models/#{model_id}:streamGenerateContent?alt=sse"
  end

  @impl true
  def build_body(%Model{}, %Context{} = context, opts) do
    body =
      %{
        "contents" => encode_messages(context.messages),
        "generationConfig" => build_generation_config(opts)
      }
      |> maybe_put_system(context.system)
      |> maybe_put_tools(context.tools)

    {:ok, body}
  end

  # Parse events — Google sends `GenerateContentResponse` objects with
  # `candidates[0].content.parts` as the primary content carrier.
  # Priority: content parts > finishReason > usageMetadata-only.

  @impl true
  def parse_event(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]} = event) do
    cond do
      fc = Enum.find(parts, &is_map_key(&1, "functionCall")) ->
        %{"functionCall" => %{"name" => name, "args" => args}} = fc

        {:tool_use_start,
         %{
           index: 0,
           id: "google_fc_#{System.unique_integer([:positive])}",
           name: name,
           input: args
         }}

      text_part = Enum.find(parts, fn p -> is_binary(p["text"]) and p["text"] != "" end) ->
        {:text_delta, %{index: 0, delta: text_part["text"]}}

      true ->
        parse_finish(event)
    end
  end

  def parse_event(%{"candidates" => [%{"finishReason" => reason} | _]} = event) do
    {:done, %{stop_reason: normalize_stop_reason(reason), usage: extract_usage(event)}}
  end

  def parse_event(%{"usageMetadata" => usage}) do
    {:usage, %{usage: normalize_usage(usage)}}
  end

  def parse_event(_), do: nil

  # Fallback for events with finishReason but content was already extracted

  defp parse_finish(%{"candidates" => [%{"finishReason" => reason} | _]} = event) do
    {:done, %{stop_reason: normalize_stop_reason(reason), usage: extract_usage(event)}}
  end

  defp parse_finish(_), do: nil

  # System encoding

  defp maybe_put_system(body, nil), do: body

  defp maybe_put_system(body, system) do
    Map.put(body, "systemInstruction", %{"parts" => [%{"text" => system}]})
  end

  # Message encoding

  defp encode_messages(messages) do
    Enum.map(messages, &encode_message/1)
  end

  defp encode_message(%{role: role, content: content}) do
    %{
      "role" => encode_role(role),
      "parts" => Enum.flat_map(content, &encode_part/1)
    }
  end

  defp encode_role(:assistant), do: "model"
  defp encode_role(:user), do: "user"

  # Content part encoding

  defp encode_part(%Text{text: text}), do: [%{"text" => text}]

  defp encode_part(%Attachment{source: {:base64, data}, media_type: mt}) do
    [%{"inlineData" => %{"mimeType" => mt, "data" => data}}]
  end

  defp encode_part(%Attachment{source: {:url, url}, media_type: mt}) do
    [%{"fileData" => %{"fileUri" => url, "mimeType" => mt}}]
  end

  defp encode_part(%ToolUse{name: name, input: args}) do
    [%{"functionCall" => %{"name" => name, "args" => args}}]
  end

  defp encode_part(%ToolResult{name: name, content: content}) do
    text =
      content
      |> Enum.filter(&match?(%Text{}, &1))
      |> Enum.map_join("", & &1.text)

    [%{"functionResponse" => %{"name" => name, "response" => %{"result" => text}}}]
  end

  defp encode_part(%Thinking{}), do: []

  # Generation config

  defp build_generation_config(opts) do
    %{}
    |> maybe_put("maxOutputTokens", Keyword.get(opts, :max_tokens))
    |> maybe_put("temperature", Keyword.get(opts, :temperature))
  end

  # Tool encoding

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) do
    declarations = Enum.map(tools, &encode_tool/1)
    Map.put(body, "tools", [%{"functionDeclarations" => declarations}])
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{"name" => name, "description" => description, "parameters" => schema}
  end

  # Usage extraction and normalization

  defp extract_usage(%{"usageMetadata" => usage}), do: normalize_usage(usage)
  defp extract_usage(_), do: nil

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["promptTokenCount"],
      "output_tokens" => usage["candidatesTokenCount"]
    }
  end

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_stop_reason("STOP"), do: :stop
  defp normalize_stop_reason("MAX_TOKENS"), do: :length
  defp normalize_stop_reason("SAFETY"), do: :content_filter
  defp normalize_stop_reason("RECITATION"), do: :content_filter
  defp normalize_stop_reason(other), do: other
end
