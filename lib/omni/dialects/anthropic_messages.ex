defmodule Omni.Dialects.AnthropicMessages do
  @moduledoc """
  Dialect for the Anthropic Messages API.

  Translates Omni types to the Anthropic Messages wire format and parses
  streaming SSE events into normalized delta tuples.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @default_max_tokens 4096

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def build_path(%Model{}), do: "/v1/messages"

  @impl true
  def build_body(%Model{} = model, %Context{} = context, opts) do
    cache = Keyword.get(opts, :cache)

    body =
      %{
        "model" => model.id,
        "messages" => encode_messages(context.messages, cache),
        "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
        "stream" => true
      }
      |> maybe_put_system(context.system, cache)
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("metadata", Keyword.get(opts, :metadata))
      |> maybe_put_tools(context.tools, cache)

    {:ok, body}
  end

  @impl true
  def parse_event(%{"type" => "message_start", "message" => %{"model" => model_id}}) do
    [{:message, %{model: model_id}}]
  end

  def parse_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "text"}
      }) do
    [{:block_start, %{type: :text, index: idx}}]
  end

  def parse_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "thinking"}
      }) do
    [{:block_start, %{type: :thinking, index: idx}}]
  end

  def parse_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
      }) do
    [{:block_start, %{type: :tool_use, index: idx, id: id, name: name}}]
  end

  def parse_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "text_delta", "text" => text}
      }) do
    [{:block_delta, %{type: :text, index: idx, delta: text}}]
  end

  def parse_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "thinking_delta", "thinking" => text}
      }) do
    [{:block_delta, %{type: :thinking, index: idx, delta: text}}]
  end

  def parse_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      }) do
    [{:block_delta, %{type: :tool_use, index: idx, delta: json}}]
  end

  def parse_event(%{"type" => "content_block_stop"}) do
    []
  end

  def parse_event(%{"type" => "message_delta", "delta" => delta} = event) do
    [
      {:message,
       %{stop_reason: normalize_stop_reason(delta["stop_reason"]), usage: event["usage"]}}
    ]
  end

  def parse_event(_), do: []

  # System encoding

  defp maybe_put_system(body, nil, _cache), do: body

  defp maybe_put_system(body, system, cache) do
    blocks = maybe_put_cache_control([%{"type" => "text", "text" => system}], cache)
    Map.put(body, "system", blocks)
  end

  # Message encoding

  defp encode_messages([], _cache), do: []

  defp encode_messages(messages, nil) do
    Enum.map(messages, &encode_message/1)
  end

  defp encode_messages(messages, cache) do
    messages
    |> Enum.map(&encode_message/1)
    |> List.update_at(-1, fn last ->
      Map.update!(last, "content", &maybe_put_cache_control(&1, cache))
    end)
  end

  defp encode_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => Enum.map(content, &encode_content/1)}
  end

  # Content block encoding

  defp encode_content(%Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_content(%Thinking{text: text, signature: signature}) do
    %{"type" => "thinking", "thinking" => text, "signature" => signature}
  end

  defp encode_content(%ToolUse{id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp encode_content(%ToolResult{tool_use_id: id, content: content, is_error: is_error}) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => Enum.map(content, &encode_content/1),
      "is_error" => is_error
    }
  end

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mt, "data" => data}}
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
  end

  defp encode_content(%Attachment{source: {:base64, data}, media_type: "application/pdf"}) do
    %{
      "type" => "document",
      "source" => %{"type" => "base64", "media_type" => "application/pdf", "data" => data}
    }
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: "application/pdf"}) do
    %{"type" => "document", "source" => %{"type" => "url", "url" => url}}
  end

  # Tool encoding

  defp maybe_put_tools(body, [], _cache), do: body
  defp maybe_put_tools(body, nil, _cache), do: body

  defp maybe_put_tools(body, tools, cache) do
    encoded =
      tools
      |> Enum.map(&encode_tool/1)
      |> maybe_put_cache_control(cache)

    Map.put(body, "tools", encoded)
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{"name" => name, "description" => description, "input_schema" => schema}
  end

  # Cache control

  defp maybe_put_cache_control(blocks, :short) do
    cache_control = %{"type" => "ephemeral"}
    List.update_at(blocks, -1, &Map.put(&1, "cache_control", cache_control))
  end

  defp maybe_put_cache_control(blocks, :long) do
    cache_control = %{"type" => "ephemeral", "ttl" => "1h"}
    List.update_at(blocks, -1, &Map.put(&1, "cache_control", cache_control))
  end

  defp maybe_put_cache_control(blocks, _), do: blocks

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_stop_reason("end_turn"), do: :stop
  defp normalize_stop_reason("stop_sequence"), do: :stop
  defp normalize_stop_reason("max_tokens"), do: :length
  defp normalize_stop_reason("tool_use"), do: :tool_use
  defp normalize_stop_reason(other), do: other
end
