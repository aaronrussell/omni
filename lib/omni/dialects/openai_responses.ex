defmodule Omni.Dialects.OpenAIResponses do
  @moduledoc """
  Dialect implementation for the OpenAI Responses wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  import Omni.Util, only: [maybe_put: 3]

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def handle_path(%Model{}, _opts), do: "/v1/responses"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body = %{
      "model" => model.id,
      "stream" => true,
      "input" => encode_input(context.messages)
    }

    body
    |> maybe_put("instructions", context.system)
    |> maybe_put("max_output_tokens", opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
    |> maybe_put("metadata", opts[:metadata])
    |> maybe_put("tools", encode_tools(context.tools))
    |> maybe_put("prompt_cache_retention", encode_cache(opts[:cache]))
    |> maybe_put("reasoning", encode_thinking(model, opts[:thinking]))
    |> maybe_put("text", encode_output(opts[:output]))
  end

  # Output schema

  defp encode_output(nil), do: nil

  defp encode_output(schema) do
    %{
      "format" => %{
        "type" => "json_schema",
        "name" => "output",
        "strict" => true,
        "schema" => schema
      }
    }
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

  def handle_event(%{"type" => "response.failed", "response" => %{"error" => error}}) do
    [{:error, error["message"] || "Response failed"}]
  end

  def handle_event(%{"type" => "error", "message" => message}) do
    [{:error, message}]
  end

  def handle_event(_), do: []

  # Thinking

  defp encode_thinking(_model, nil), do: nil
  defp encode_thinking(%Model{reasoning: false}, _thinking), do: nil
  defp encode_thinking(_model, false), do: %{"effort" => "none"}

  defp encode_thinking(_model, level) when is_atom(level) do
    %{"effort" => effort_string(level), "summary" => "auto"}
  end

  defp encode_thinking(_model, %{} = opts) do
    level = Map.get(opts, :effort, :high)
    %{"effort" => effort_string(level), "summary" => "auto"}
  end

  defp effort_string(:low), do: "low"
  defp effort_string(:medium), do: "medium"
  defp effort_string(:high), do: "high"
  defp effort_string(:max), do: "xhigh"

  # Input encoding — flat-maps messages into a mixed array

  defp encode_input(messages) do
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(%{role: :assistant, content: content}) do
    {text_blocks, tool_uses} = split_assistant_content(content)

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
    Enum.reduce(content, {[], []}, fn
      %Text{} = t, {texts, tools} -> {[t | texts], tools}
      %ToolUse{} = tu, {texts, tools} -> {texts, [tu | tools]}
      _, acc -> acc
    end)
    |> then(fn {texts, tools} ->
      {Enum.reverse(texts), Enum.reverse(tools)}
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

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil
  defp encode_tools(tools), do: Enum.map(tools, &encode_tool/1)

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => schema
    }
  end

  # Cache control

  defp encode_cache(:long), do: "24h"
  defp encode_cache(_), do: nil

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
end
