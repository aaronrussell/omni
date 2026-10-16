defmodule Omni.Dialects.AnthropicMessages do
  @moduledoc """
  Dialect implementation for the Anthropic Messages wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.

  ## Compat flags

  None yet: providers speaking this dialect get its home API's behaviour.
  Flags are added as verified providers need them.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Dialect, Model}

  import Omni.Util, only: [maybe_put: 3]

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  # Models that reject non-default sampling parameters (temperature/top_p/top_k).
  # Opus 4.7 returns a 400 on any non-default value, even when thinking is off.
  @strict_sampling_prefixes ["claude-opus-4-7"]

  @impl true
  def option_schema, do: %{max_tokens: {:integer, {:default, 4096}}}

  @impl true
  def compat_schema, do: %{}
  @impl true
  def auth, do: {:header, "x-api-key"}

  @impl true
  def handle_path(%Model{}, _opts), do: "/messages"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    cache = opts[:cache]

    body = %{
      "model" => model.id,
      "messages" => encode_messages(context.messages, cache),
      "max_tokens" => opts[:max_tokens],
      "stream" => true
    }

    body
    |> maybe_put("system", encode_system(context.system, cache))
    |> maybe_put("temperature", sampling_temperature(model, opts))
    |> maybe_put("metadata", opts[:metadata])
    |> maybe_put("tools", encode_tools(context.tools, cache))
    |> apply_thinking(model, opts[:thinking])
    |> apply_output(opts[:output])
  end

  @impl true
  def handle_event(
        %{"type" => "message_start", "message" => %{"model" => model_id} = message},
        _model
      ) do
    [{:message, %{model: model_id} |> maybe_put(:usage, normalize_usage(message["usage"]))}]
  end

  def handle_event(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "text"}
        },
        _model
      ) do
    [{:block_start, %{type: :text, index: idx}}]
  end

  def handle_event(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "thinking"}
        },
        _model
      ) do
    [{:block_start, %{type: :thinking, index: idx}}]
  end

  def handle_event(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "redacted_thinking", "data" => data}
        },
        _model
      ) do
    [{:block_start, %{type: :thinking, index: idx, redacted_data: data}}]
  end

  def handle_event(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
        },
        _model
      ) do
    [{:block_start, %{type: :tool_use, index: idx, id: id, name: name}}]
  end

  def handle_event(
        %{
          "type" => "content_block_delta",
          "index" => idx,
          "delta" => %{"type" => "text_delta", "text" => text}
        },
        _model
      ) do
    [{:block_delta, %{type: :text, index: idx, delta: text}}]
  end

  def handle_event(
        %{
          "type" => "content_block_delta",
          "index" => idx,
          "delta" => %{"type" => "thinking_delta", "thinking" => text}
        },
        _model
      )
      when is_binary(text) and text != "" do
    [{:block_delta, %{type: :thinking, index: idx, delta: text}}]
  end

  def handle_event(
        %{
          "type" => "content_block_delta",
          "index" => idx,
          "delta" => %{"type" => "signature_delta", "signature" => sig}
        },
        _model
      ) do
    [{:block_delta, %{type: :thinking, index: idx, signature: sig}}]
  end

  def handle_event(
        %{
          "type" => "content_block_delta",
          "index" => idx,
          "delta" => %{"type" => "input_json_delta", "partial_json" => json}
        },
        _model
      ) do
    [{:block_delta, %{type: :tool_use, index: idx, delta: json}}]
  end

  def handle_event(%{"type" => "content_block_stop"}, _model) do
    []
  end

  def handle_event(%{"type" => "error", "error" => %{"message" => message}}, _model) do
    [{:error, message}]
  end

  def handle_event(%{"type" => "message_delta", "delta" => delta} = event, _model) do
    message =
      %{}
      |> maybe_put(:stop_reason, normalize_stop_reason(delta["stop_reason"]))
      |> maybe_put(:usage, normalize_usage(event["usage"]))

    [{:message, message}]
  end

  def handle_event(_, _model), do: []

  # Thinking

  # Models listing effort values and no budget range use adaptive thinking
  # (type: "adaptive" + output_config.effort); the rest, including models
  # with no thinking data, use budget-based thinking.
  defp apply_thinking(body, model, option) do
    case Dialect.Thinking.resolve(model, option) do
      nil ->
        body

      :off ->
        Map.put(body, "thinking", %{"type" => "disabled"})

      :dynamic ->
        if adaptive?(model),
          do: put_adaptive(body, nil),
          else: apply_thinking(body, model, :medium)

      %{effort: effort, level: level, budget: budget} ->
        if adaptive?(model),
          do: put_adaptive(body, effort || Atom.to_string(level)),
          else: put_budget(body, budget || Dialect.Thinking.budget(model, level))
    end
  end

  defp put_adaptive(body, effort) do
    body
    |> Map.delete("temperature")
    |> Map.put("thinking", %{"type" => "adaptive", "display" => "summarized"})
    |> maybe_put("output_config", if(effort, do: %{"effort" => effort}))
  end

  defp put_budget(body, budget) do
    body
    |> Map.delete("temperature")
    |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
    |> Map.put("max_tokens", body["max_tokens"] + budget)
  end

  defp adaptive?(%Model{thinking: %{efforts: _} = thinking}),
    do: not Map.has_key?(thinking, :budget)

  defp adaptive?(_model), do: false

  defp strict_sampling_model?(%Model{id: id}) do
    Enum.any?(@strict_sampling_prefixes, &String.starts_with?(id, &1))
  end

  defp sampling_temperature(model, opts) do
    if strict_sampling_model?(model), do: nil, else: opts[:temperature]
  end

  # Output schema

  defp apply_output(body, nil), do: body

  defp apply_output(body, schema) do
    existing = Map.get(body, "output_config", %{})
    schema = schema |> Omni.Schema.to_schema() |> apply_strict()
    format = %{"type" => "json_schema", "schema" => schema}
    Map.put(body, "output_config", Map.put(existing, "format", format))
  end

  defp apply_strict(%{type: "object"} = schema) do
    Omni.Schema.update(schema, additional_properties: false)
  end

  defp apply_strict(schema), do: schema

  # System encoding

  defp encode_system(nil, _cache), do: nil

  defp encode_system(system, cache) do
    maybe_put_cache_control([%{"type" => "text", "text" => system}], cache)
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

  defp encode_tools(nil, _cache), do: nil
  defp encode_tools([], _cache), do: nil

  defp encode_tools(tools, cache) do
    tools
    |> Enum.map(&encode_tool/1)
    |> maybe_put_cache_control(cache)
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{
      "name" => name,
      "description" => description,
      "input_schema" => Omni.Schema.to_schema(schema)
    }
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

  # Usage normalization

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    %{}
    |> maybe_put("input_tokens", usage["input_tokens"])
    |> maybe_put("output_tokens", usage["output_tokens"])
    |> maybe_put("cache_read_tokens", usage["cache_read_input_tokens"])
    |> maybe_put("cache_write_tokens", usage["cache_creation_input_tokens"])
  end

  # Helpers

  defp normalize_stop_reason(nil), do: nil
  defp normalize_stop_reason("end_turn"), do: :stop
  defp normalize_stop_reason("stop_sequence"), do: :stop
  defp normalize_stop_reason("max_tokens"), do: :length
  defp normalize_stop_reason("tool_use"), do: :tool_use
  defp normalize_stop_reason("pause_turn"), do: :length
  defp normalize_stop_reason("refusal"), do: :refusal
  defp normalize_stop_reason("model_context_window_exceeded"), do: :length
  defp normalize_stop_reason(_), do: :stop
end
