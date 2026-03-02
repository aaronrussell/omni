defmodule Omni.Dialects.OpenAICompletions do
  @moduledoc """
  Dialect implementation for the OpenAI Chat Completions wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def handle_path(%Model{}, _opts), do: "/v1/chat/completions"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body =
      %{
        "model" => model.id,
        "messages" => encode_messages(context.system, context.messages),
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      }
      |> maybe_put("max_completion_tokens", opts[:max_tokens])
      |> maybe_put("temperature", opts[:temperature])
      |> maybe_put("metadata", opts[:metadata])
      |> maybe_put_tools(context.tools)
      |> maybe_put_cache(opts[:cache])
      |> maybe_put_thinking(model, opts[:thinking])
      |> maybe_put_output(opts[:output])

    body
  end

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body
  defp maybe_put_thinking(body, _model, false), do: body
  defp maybe_put_thinking(body, _model, :none), do: body
  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body

  defp maybe_put_thinking(body, _model, thinking) do
    case normalize_thinking(thinking) do
      {:effort, level} ->
        Map.put(body, "reasoning_effort", effort_string(level))

      {:effort, level, _budget} ->
        Map.put(body, "reasoning_effort", effort_string(level))
    end
  end

  defp effort_string(:low), do: "low"
  defp effort_string(:medium), do: "medium"
  defp effort_string(:high), do: "high"
  defp effort_string(:max), do: "max"

  defp normalize_thinking(true), do: {:effort, :high}
  defp normalize_thinking(level) when level in [:low, :medium, :high, :max], do: {:effort, level}

  defp normalize_thinking(opts) when is_list(opts) do
    {:effort, Keyword.get(opts, :effort, :high), Keyword.get(opts, :budget)}
  end

  # Output schema

  defp maybe_put_output(body, nil), do: body

  defp maybe_put_output(body, schema) do
    Map.put(body, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "output", "strict" => true, "schema" => schema}
    })
  end

  # Parse events — OpenAI sends homogeneous `chat.completion.chunk` objects

  @impl true
  def handle_event(%{"usage" => %{} = usage}) do
    [{:message, %{usage: normalize_usage(usage)}}]
  end

  def handle_event(%{"choices" => [%{"finish_reason" => reason}]}) when is_binary(reason) do
    [{:message, %{stop_reason: normalize_stop_reason(reason)}}]
  end

  def handle_event(%{"choices" => [%{"delta" => %{"tool_calls" => [tool_call | _]}}]} = event)
      when is_map_key(tool_call, "id") do
    message =
      case event do
        %{"model" => model_id} -> [{:message, %{model: model_id}}]
        _ -> []
      end

    message ++
      [
        {:block_start,
         %{
           type: :tool_use,
           index: tool_call["index"] || 0,
           id: tool_call["id"],
           name: tool_call["function"]["name"]
         }}
      ]
  end

  def handle_event(%{"choices" => [%{"delta" => %{"tool_calls" => [tool_call | _]}}]}) do
    [
      {:block_delta,
       %{
         type: :tool_use,
         index: tool_call["index"] || 0,
         delta: tool_call["function"]["arguments"]
       }}
    ]
  end

  def handle_event(%{"choices" => [%{"delta" => %{"reasoning_content" => content}}]})
      when is_binary(content) and content != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: content}}]
  end

  # OpenRouter and vLLM use "reasoning" instead of DeepSeek's "reasoning_content".
  # Both are legitimate field names in the Completions wire format ecosystem.
  def handle_event(%{"choices" => [%{"delta" => %{"reasoning" => content}}]})
      when is_binary(content) and content != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: content}}]
  end

  def handle_event(%{"choices" => [%{"delta" => %{"content" => content}}]})
      when is_binary(content) and content != "" do
    [{:block_delta, %{type: :text, index: 0, delta: content}}]
  end

  def handle_event(%{
        "choices" => [%{"delta" => %{"role" => "assistant"}}],
        "model" => model_id
      }) do
    [{:message, %{model: model_id}}]
  end

  def handle_event(_), do: []

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

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt}) do
    %{"type" => "file", "file" => %{"file_data" => "data:#{mt};base64,#{data}"}}
  end

  defp encode_content(%Attachment{source: {:url, url}}) do
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
  defp normalize_stop_reason("content_filter"), do: :refusal
  defp normalize_stop_reason("function_call"), do: :tool_use
  defp normalize_stop_reason(_), do: :stop
end
