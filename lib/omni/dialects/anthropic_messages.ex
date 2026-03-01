defmodule Omni.Dialects.AnthropicMessages do
  @moduledoc """
  Dialect for the Anthropic Messages API.

  Translates Omni types to the Anthropic Messages wire format and parses
  streaming SSE events into normalized delta tuples.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{max_tokens: {:integer, {:default, 4096}}}

  @impl true
  def handle_path(%Model{}, _opts), do: "/v1/messages"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    cache = opts[:cache]

    body =
      %{
        "model" => model.id,
        "messages" => encode_messages(context.messages, cache),
        "max_tokens" => opts[:max_tokens],
        "stream" => true
      }
      |> maybe_put_system(context.system, cache)
      |> maybe_put("temperature", opts[:temperature])
      |> maybe_put("metadata", opts[:metadata])
      |> maybe_put_tools(context.tools, cache)
      |> maybe_put_thinking(model, opts[:thinking])
      |> maybe_put_output(opts[:output])

    body
  end

  @impl true
  def handle_event(%{"type" => "message_start", "message" => %{"model" => model_id}}) do
    [{:message, %{model: model_id}}]
  end

  def handle_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "text"}
      }) do
    [{:block_start, %{type: :text, index: idx}}]
  end

  def handle_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "thinking"}
      }) do
    [{:block_start, %{type: :thinking, index: idx}}]
  end

  def handle_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "redacted_thinking", "data" => data}
      }) do
    [{:block_start, %{type: :thinking, index: idx, redacted_data: data}}]
  end

  def handle_event(%{
        "type" => "content_block_start",
        "index" => idx,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
      }) do
    [{:block_start, %{type: :tool_use, index: idx, id: id, name: name}}]
  end

  def handle_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "text_delta", "text" => text}
      }) do
    [{:block_delta, %{type: :text, index: idx, delta: text}}]
  end

  def handle_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "thinking_delta", "thinking" => text}
      })
      when is_binary(text) and text != "" do
    [{:block_delta, %{type: :thinking, index: idx, delta: text}}]
  end

  def handle_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "signature_delta", "signature" => sig}
      }) do
    [{:block_delta, %{type: :thinking, index: idx, signature: sig}}]
  end

  def handle_event(%{
        "type" => "content_block_delta",
        "index" => idx,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      }) do
    [{:block_delta, %{type: :tool_use, index: idx, delta: json}}]
  end

  def handle_event(%{"type" => "content_block_stop"}) do
    []
  end

  def handle_event(%{"type" => "error", "error" => %{"message" => message}}) do
    [{:error, message}]
  end

  def handle_event(%{"type" => "message_delta", "delta" => delta} = event) do
    [
      {:message,
       %{stop_reason: normalize_stop_reason(delta["stop_reason"]), usage: event["usage"]}}
    ]
  end

  def handle_event(_), do: []

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body

  defp maybe_put_thinking(body, _model, false) do
    Map.put(body, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(body, _model, :none) do
    Map.put(body, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body

  defp maybe_put_thinking(body, model, thinking) do
    case normalize_thinking(thinking) do
      {:effort, level} ->
        put_thinking_config(body, model, level, nil)

      {:effort, level, budget} ->
        put_thinking_config(body, model, level, budget)
    end
  end

  defp put_thinking_config(body, model, level, budget) do
    body = Map.delete(body, "temperature")

    if adaptive_model?(model) do
      body
      |> Map.put("thinking", %{"type" => "adaptive"})
      |> Map.put("output_config", %{"effort" => to_string(level)})
    else
      budget = budget || effort_to_budget(level)
      max_tokens = body["max_tokens"] + budget

      body
      |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
      |> Map.put("max_tokens", max_tokens)
    end
  end

  defp adaptive_model?(%Model{id: id}), do: String.contains?(id, "4.6")

  defp effort_to_budget(:low), do: 1024
  defp effort_to_budget(:medium), do: 4096
  defp effort_to_budget(:high), do: 16384
  defp effort_to_budget(:max), do: 32768

  defp normalize_thinking(false), do: :none
  defp normalize_thinking(true), do: {:effort, :high}
  defp normalize_thinking(:none), do: :none
  defp normalize_thinking(level) when level in [:low, :medium, :high, :max], do: {:effort, level}

  defp normalize_thinking(opts) when is_list(opts) do
    {:effort, Keyword.get(opts, :effort, :high), Keyword.get(opts, :budget)}
  end

  # Output schema

  defp maybe_put_output(body, nil), do: body

  defp maybe_put_output(body, schema) do
    existing = Map.get(body, "output_config", %{})
    format = %{"type" => "json_schema", "schema" => maybe_put_strict(schema)}
    Map.put(body, "output_config", Map.put(existing, "format", format))
  end

  defp maybe_put_strict(%{type: "object"} = schema) do
    Map.put(schema, :additionalProperties, false)
  end

  defp maybe_put_strict(schema), do: schema

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

  defp encode_content(%Thinking{redacted_data: data}) when is_binary(data) do
    %{"type" => "redacted_thinking", "data" => data}
  end

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

  defp encode_content(%Attachment{source: {:base64, data}, media_type: "text/plain"}) do
    %{
      "type" => "document",
      "source" => %{
        "type" => "text",
        "media_type" => "text/plain",
        "data" => Base.decode64!(data)
      }
    }
  end

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt})
       when mt not in @image_media_types do
    %{
      "type" => "document",
      "source" => %{"type" => "base64", "media_type" => mt, "data" => data}
    }
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: mt})
       when mt not in @image_media_types do
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
