defmodule Omni.Dialects.OpenAIResponses do
  @moduledoc """
  Dialect for the OpenAI Responses API.

  Translates Omni types to the OpenAI Responses wire format and parses
  streaming SSE events into normalized delta tuples.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def handle_path(%Model{}, _opts), do: "/v1/responses"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body =
      %{
        "model" => model.id,
        "stream" => true,
        "input" => encode_input(context.messages)
      }
      |> maybe_put("instructions", context.system)
      |> maybe_put("max_output_tokens", opts[:max_tokens])
      |> maybe_put("temperature", opts[:temperature])
      |> maybe_put("metadata", opts[:metadata])
      |> maybe_put_tools(context.tools)
      |> maybe_put_cache(opts[:cache])
      |> maybe_put_thinking(model, opts[:thinking])

    body
  end

  # Parse events — OpenAI Responses sends named events with "type" field

  @impl true
  def handle_event(%{"type" => "response.created", "response" => %{"model" => model_id}}) do
    [{:message, %{model: model_id}}]
  end

  def handle_event(%{
        "type" => "response.output_text.delta",
        "output_index" => output_index,
        "delta" => delta
      }) do
    [{:block_delta, %{type: :text, index: output_index, delta: delta}}]
  end

  def handle_event(%{
        "type" => "response.output_item.added",
        "output_index" => output_index,
        "item" => %{"type" => "function_call", "call_id" => call_id, "name" => name}
      }) do
    [{:block_start, %{type: :tool_use, index: output_index, id: call_id, name: name}}]
  end

  def handle_event(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => output_index,
        "delta" => delta
      }) do
    [{:block_delta, %{type: :tool_use, index: output_index, delta: delta}}]
  end

  def handle_event(%{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => output_index,
        "delta" => delta
      }) do
    [{:block_delta, %{type: :thinking, index: output_index, delta: delta}}]
  end

  def handle_event(%{"type" => "response.completed", "response" => response}) do
    [{:message, %{stop_reason: infer_stop_reason(response), usage: normalize_usage(response)}}]
  end

  def handle_event(_), do: []

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body
  defp maybe_put_thinking(body, _model, false), do: body
  defp maybe_put_thinking(body, _model, :none), do: body
  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body

  defp maybe_put_thinking(body, _model, thinking) do
    case normalize_thinking(thinking) do
      {:effort, level} ->
        effort = effort_string(level)
        Map.put(body, "reasoning", %{"effort" => effort, "summary" => "auto"})

      {:effort, level, _budget} ->
        effort = effort_string(level)
        Map.put(body, "reasoning", %{"effort" => effort, "summary" => "auto"})
    end
  end

  defp effort_string(:low), do: "low"
  defp effort_string(:medium), do: "medium"
  defp effort_string(:high), do: "high"
  defp effort_string(:max), do: "high"

  defp normalize_thinking(true), do: {:effort, :high}
  defp normalize_thinking(level) when level in [:low, :medium, :high, :max], do: {:effort, level}

  defp normalize_thinking(opts) when is_list(opts) do
    {:effort, Keyword.get(opts, :effort, :high), Keyword.get(opts, :budget)}
  end

  # Input encoding — flat-maps messages into a mixed array

  defp encode_input(messages) do
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(%{role: :assistant, content: content}) do
    {text_blocks, tool_uses, _other} = split_assistant_content(content)

    msg =
      case text_blocks do
        [] ->
          nil

        texts ->
          %{
            "role" => "assistant",
            "content" => Enum.map(texts, &%{"type" => "output_text", "text" => &1.text})
          }
      end

    tool_items =
      Enum.map(tool_uses, fn %ToolUse{id: id, name: name, input: input} ->
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => name,
          "arguments" => JSON.encode!(input)
        }
      end)

    Enum.reject([msg | tool_items], &is_nil/1)
  end

  defp encode_message(%{role: :user, content: content}) do
    {tool_results, other_content} = Enum.split_with(content, &match?(%ToolResult{}, &1))

    tool_items =
      Enum.map(tool_results, fn %ToolResult{tool_use_id: id, content: result_content} ->
        text =
          result_content
          |> Enum.filter(&match?(%Text{}, &1))
          |> Enum.map_join("", & &1.text)

        %{"type" => "function_call_output", "call_id" => id, "output" => text}
      end)

    user_msg =
      case other_content do
        [] ->
          []

        [%Text{text: text}] ->
          [%{"role" => "user", "content" => text}]

        blocks ->
          [%{"role" => "user", "content" => Enum.map(blocks, &encode_content/1)}]
      end

    tool_items ++ user_msg
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

  defp encode_content(%Text{text: text}), do: %{"type" => "input_text", "text" => text}

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "input_image", "image_url" => "data:#{mt};base64,#{data}"}
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: mt})
       when mt in @image_media_types do
    %{"type" => "input_image", "image_url" => url}
  end

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt}) do
    %{"type" => "input_file", "file_data" => "data:#{mt};base64,#{data}"}
  end

  defp encode_content(%Attachment{source: {:url, url}}) do
    %{"type" => "input_file", "file_url" => url}
  end

  # Tool encoding — flattened format (no "function" wrapper)

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &encode_tool/1))
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => schema
    }
  end

  # Cache control

  defp maybe_put_cache(body, :long), do: Map.put(body, "prompt_cache_retention", "24h")
  defp maybe_put_cache(body, _), do: body

  # Stop reason inference

  defp infer_stop_reason(%{"status" => "completed", "output" => output}) do
    if Enum.any?(output, &match?(%{"type" => "function_call"}, &1)),
      do: :tool_use,
      else: :stop
  end

  defp infer_stop_reason(%{"status" => "incomplete"}), do: :length
  defp infer_stop_reason(_), do: :stop

  # Usage normalization

  defp normalize_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      "input_tokens" => usage["input_tokens"],
      "output_tokens" => usage["output_tokens"]
    }
  end

  defp normalize_usage(_), do: nil

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
