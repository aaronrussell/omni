defmodule Omni.Dialects.OpenAICompletions do
  @moduledoc """
  Dialect for the OpenAI Chat Completions API.

  Translates Omni types to the OpenAI Chat Completions wire format and parses
  streaming SSE events into normalized delta tuples.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def build_path(%Model{}), do: "/v1/chat/completions"

  @impl true
  def build_body(%Model{} = model, %Context{} = context, opts) do
    body =
      %{
        "model" => model.id,
        "messages" => encode_messages(context.system, context.messages),
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      }
      |> maybe_put("max_completion_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("metadata", Keyword.get(opts, :metadata))
      |> maybe_put_tools(context.tools)
      |> maybe_put_cache(Keyword.get(opts, :cache))

    {:ok, body}
  end

  # Parse events — OpenAI sends homogeneous `chat.completion.chunk` objects

  @impl true
  def parse_event(%{"choices" => [], "usage" => usage}) do
    {:usage, %{usage: normalize_usage(usage)}}
  end

  def parse_event(%{"choices" => [%{"finish_reason" => reason}]}) when is_binary(reason) do
    {:done, %{stop_reason: normalize_stop_reason(reason)}}
  end

  def parse_event(%{"choices" => [%{"delta" => %{"tool_calls" => [tool_call | _]}} = choice]})
      when is_map_key(tool_call, "id") do
    {:tool_use_start,
     %{
       index: choice["index"] || 0,
       id: tool_call["id"],
       name: tool_call["function"]["name"]
     }}
  end

  def parse_event(%{"choices" => [%{"delta" => %{"tool_calls" => [tool_call | _]}} = choice]}) do
    {:tool_use_delta,
     %{
       index: choice["index"] || 0,
       delta: tool_call["function"]["arguments"]
     }}
  end

  def parse_event(%{
        "choices" => [%{"delta" => %{"role" => "assistant"}}],
        "model" => model_id
      }) do
    {:start, %{model: model_id}}
  end

  def parse_event(%{"choices" => [%{"delta" => %{"content" => content}}]})
      when is_binary(content) and content != "" do
    {:text_delta, %{index: 0, delta: content}}
  end

  def parse_event(_), do: nil

  # Message encoding

  defp encode_messages(system, messages) do
    system_msg =
      case system do
        nil -> []
        text -> [%{"role" => "system", "content" => text}]
      end

    system_msg ++ Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(%{role: :assistant, content: content}) do
    {text_blocks, tool_uses, _other} = split_assistant_content(content)

    msg = %{"role" => "assistant"}

    msg =
      case text_blocks do
        [] -> msg
        texts -> Map.put(msg, "content", Enum.map_join(texts, "", & &1.text))
      end

    msg =
      case tool_uses do
        [] -> msg
        uses -> Map.put(msg, "tool_calls", Enum.with_index(uses, &encode_tool_call/2))
      end

    [msg]
  end

  defp encode_message(%{role: :user, content: content}) do
    {tool_results, other_content} = Enum.split_with(content, &match?(%ToolResult{}, &1))

    tool_msgs = Enum.map(tool_results, &encode_tool_result/1)

    user_msg =
      case other_content do
        [] ->
          []

        [%Text{text: text}] ->
          [%{"role" => "user", "content" => text}]

        blocks ->
          [%{"role" => "user", "content" => Enum.map(blocks, &encode_content/1)}]
      end

    tool_msgs ++ user_msg
  end

  defp split_assistant_content(content) do
    Enum.reduce(content, {[], [], []}, fn
      %Text{} = t, {texts, tools, other} -> {[t | texts], tools, other}
      %ToolUse{} = tu, {texts, tools, other} -> {texts, [tu | tools], other}
      %Thinking{}, {texts, tools, other} -> {texts, tools, other}
      other_block, {texts, tools, other} -> {texts, tools, [other_block | other]}
    end)
    |> then(fn {texts, tools, other} ->
      {Enum.reverse(texts), Enum.reverse(tools), Enum.reverse(other)}
    end)
  end

  # Content block encoding

  defp encode_content(%Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{mt};base64,#{data}"}}
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  # Tool call encoding (assistant messages)

  defp encode_tool_call(%ToolUse{id: id, name: name, input: input}, index) do
    %{
      "id" => id,
      "index" => index,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => JSON.encode!(input)
      }
    }
  end

  # Tool result encoding (separate "tool" role messages)

  defp encode_tool_result(%ToolResult{tool_use_id: id, content: content}) do
    text =
      content
      |> Enum.filter(&match?(%Text{}, &1))
      |> Enum.map_join("", & &1.text)

    %{"role" => "tool", "tool_call_id" => id, "content" => text}
  end

  # Tool schema encoding

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &encode_tool/1))
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => schema
      }
    }
  end

  # Cache control

  defp maybe_put_cache(body, :long), do: Map.put(body, "prompt_cache_retention", "24h")
  defp maybe_put_cache(body, _), do: body

  # Usage normalization

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"],
      "output_tokens" => usage["completion_tokens"]
    }
  end

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_stop_reason("stop"), do: :stop
  defp normalize_stop_reason("length"), do: :length
  defp normalize_stop_reason("tool_calls"), do: :tool_use
  defp normalize_stop_reason("content_filter"), do: :content_filter
  defp normalize_stop_reason(other), do: other
end
