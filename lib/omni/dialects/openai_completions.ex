defmodule Omni.Dialects.OpenAICompletions do
  @moduledoc """
  Dialect implementation for the OpenAI Chat Completions wire format.

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
  def handle_path(%Model{}, _opts), do: "/v1/chat/completions"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body = %{
      "model" => model.id,
      "messages" => encode_messages(context.system, context.messages),
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    body
    |> maybe_put("max_completion_tokens", opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
    |> maybe_put("metadata", opts[:metadata])
    |> maybe_put("tools", encode_tools(context.tools))
    |> maybe_put("prompt_cache_retention", encode_cache(opts[:cache]))
    |> maybe_put("reasoning_effort", encode_thinking(model, opts[:thinking]))
    |> maybe_put("response_format", encode_output(opts[:output]))
  end

  # Thinking

  defp encode_thinking(_model, nil), do: nil
  defp encode_thinking(%Model{reasoning: false}, _thinking), do: nil
  defp encode_thinking(_model, false), do: "none"
  defp encode_thinking(_model, level) when is_atom(level), do: effort_string(level)

  defp encode_thinking(_model, %{} = opts) do
    opts |> Map.get(:effort, :high) |> effort_string()
  end

  defp effort_string(:low), do: "low"
  defp effort_string(:medium), do: "medium"
  defp effort_string(:high), do: "high"
  defp effort_string(:xhigh), do: "xhigh"
  defp effort_string(:max), do: "xhigh"

  # Output schema

  defp encode_output(nil), do: nil

  defp encode_output(schema) do
    %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "output", "strict" => true, "schema" => schema}
    }
  end

  # Parse events — OpenAI sends homogeneous `chat.completion.chunk` objects

  @impl true
  def handle_event(%{"choices" => [%{"finish_reason" => reason}]} = event)
      when is_binary(reason) do
    message =
      %{stop_reason: normalize_stop_reason(reason)}
      |> maybe_put(:usage, normalize_usage(event["usage"]))

    [{:message, message}]
  end

  def handle_event(
        %{
          "choices" => [
            %{"delta" => %{"tool_calls" => [%{"function" => %{"name" => name}} = tool_call | _]}}
          ]
        } = event
      )
      when is_binary(name) do
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
           name: name
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

  def handle_event(
        %{
          "choices" => [%{"delta" => %{"role" => "assistant"}}],
          "model" => model_id
        } = event
      ) do
    message =
      %{model: model_id}
      |> maybe_put(:usage, normalize_usage(event["usage"]))

    [{:message, message}]
  end

  # Usage may arrive in a standalone chunk or combined with choices (e.g.
  # OpenRouter). Choices handlers above match first; this catches the rest.
  def handle_event(%{"usage" => %{} = usage}) do
    [{:message, %{usage: normalize_usage(usage)}}]
  end

  def handle_event(%{"error" => %{"message" => message}}) do
    [{:error, message}]
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
    {text_blocks, tool_uses} = split_assistant_content(content)

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

  # Chat Completions has no generic URL content type — "image_url" is the only
  # URL-based input the API accepts. Non-image URLs (e.g. PDFs) work through
  # this wrapper on providers that support them.
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

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil
  defp encode_tools(tools), do: Enum.map(tools, &encode_tool/1)

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

  defp encode_cache(:long), do: "24h"
  defp encode_cache(_), do: nil

  # Usage normalization

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"],
      "output_tokens" => usage["completion_tokens"]
    }
  end

  # Helpers

  defp normalize_stop_reason("stop"), do: :stop
  defp normalize_stop_reason("length"), do: :length
  defp normalize_stop_reason("tool_calls"), do: :tool_use
  defp normalize_stop_reason("content_filter"), do: :refusal
  defp normalize_stop_reason("function_call"), do: :tool_use

  # Non-standard finish_reason values emitted by Z.ai's GLM models. Mapped
  # here rather than in the provider to keep stop-reason normalisation in one
  # place — modify_events would have to re-walk the event to rewrite them.
  defp normalize_stop_reason("sensitive"), do: :refusal
  defp normalize_stop_reason("model_context_window_exceeded"), do: :length
  defp normalize_stop_reason("network_error"), do: :error

  defp normalize_stop_reason(_), do: :stop
end
