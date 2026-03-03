defmodule Omni.Dialects.OllamaChat do
  @moduledoc """
  Dialect implementation for the Ollama native chat API wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.

  ## Notable differences

  - Uses NDJSON streaming instead of SSE — each line is a complete JSON object
  - Tool call arguments arrive complete (as a map, not streamed JSON fragments),
    similar to Google Gemini
  - Thinking content arrives in a `message.thinking` field alongside `message.content`
  - Options like `max_tokens` and `temperature` are nested under `"options"` in the
    request body
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @impl true
  def option_schema, do: %{}

  @impl true
  def handle_path(%Model{}, _opts), do: "/api/chat"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    %{
      "model" => model.id,
      "messages" => encode_messages(context.system, context.messages),
      "stream" => true
    }
    |> maybe_put_tools(context.tools)
    |> maybe_put_options(opts)
    |> maybe_put_thinking(model, opts[:thinking])
    |> maybe_put_output(opts[:output])
  end

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body
  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body
  defp maybe_put_thinking(body, _model, false), do: Map.put(body, "think", false)

  defp maybe_put_thinking(body, _model, thinking) do
    value =
      case normalize_thinking(thinking) do
        {:effort, :high} -> true
        {:effort, :max} -> true
        {:effort, level} -> Atom.to_string(level)
        {:effort, _level, _budget} -> true
      end

    Map.put(body, "think", value)
  end

  defp normalize_thinking(level) when level in [:low, :medium, :high, :max], do: {:effort, level}

  defp normalize_thinking(opts) when is_map(opts) do
    {:effort, Map.get(opts, :effort, :high), Map.get(opts, :budget)}
  end

  # Output schema

  defp maybe_put_output(body, nil), do: body

  defp maybe_put_output(body, schema) do
    Map.put(body, "format", schema)
  end

  # Options (temperature, max_tokens → num_predict)

  defp maybe_put_options(body, opts) do
    options =
      %{}
      |> maybe_put("temperature", opts[:temperature])
      |> maybe_put("num_predict", opts[:max_tokens])

    case options do
      empty when empty == %{} -> body
      options -> Map.put(body, "options", options)
    end
  end

  # Parse events — Ollama sends one JSON object per NDJSON line

  @impl true
  def handle_event(%{"done" => true} = event) do
    message =
      %{}
      |> maybe_put_stop_reason(event)
      |> maybe_put_usage(event)

    # Handle any final content in the done event
    content = extract_content(event)

    case message do
      empty when empty == %{} -> content
      data -> content ++ [{:message, data}]
    end
  end

  def handle_event(%{"message" => _} = event) do
    message = extract_model(event)
    content = extract_content(event)

    case message do
      data when data == %{} -> content
      data -> [{:message, data}] ++ content
    end
  end

  def handle_event(_), do: []

  defp extract_model(%{"model" => model_id}), do: %{model: model_id}
  defp extract_model(_), do: %{}

  defp extract_content(%{"message" => msg}) do
    thinking = extract_thinking(msg)
    text = extract_text(msg)
    tool_calls = extract_tool_calls(msg)

    thinking ++ text ++ tool_calls
  end

  defp extract_content(_), do: []

  defp extract_thinking(%{"thinking" => thinking})
       when is_binary(thinking) and thinking != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: thinking}}]
  end

  defp extract_thinking(_), do: []

  defp extract_text(%{"content" => content})
       when is_binary(content) and content != "" do
    [{:block_delta, %{type: :text, index: 0, delta: content}}]
  end

  defp extract_text(_), do: []

  defp extract_tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {tc, _idx} ->
      func = tc["function"] || %{}

      {:block_start,
       %{
         type: :tool_use,
         index: System.unique_integer([:positive, :monotonic]),
         id: tc["id"] || "ollama_tc_#{System.unique_integer([:positive])}",
         name: func["name"],
         input: parse_arguments(func["arguments"])
       }}
    end)
  end

  defp extract_tool_calls(_), do: []

  defp parse_arguments(args) when is_map(args), do: args

  defp parse_arguments(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(_), do: %{}

  defp maybe_put_stop_reason(map, %{"done_reason" => reason}) when is_binary(reason) do
    Map.put(map, :stop_reason, normalize_stop_reason(reason))
  end

  defp maybe_put_stop_reason(map, _), do: map

  defp maybe_put_usage(map, event) do
    input = event["prompt_eval_count"]
    output = event["eval_count"]

    if input || output do
      Map.put(map, :usage, %{
        "input_tokens" => input || 0,
        "output_tokens" => output || 0
      })
    else
      map
    end
  end

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
    {text_blocks, tool_uses, thinking_blocks} = split_assistant_content(content)

    msg = %{"role" => "assistant"}

    msg =
      case text_blocks do
        [] -> msg
        texts -> Map.put(msg, "content", Enum.map_join(texts, "", & &1.text))
      end

    msg =
      case thinking_blocks do
        [] -> msg
        thinks -> Map.put(msg, "thinking", Enum.map_join(thinks, "", & &1.text))
      end

    msg =
      case tool_uses do
        [] -> msg
        uses -> Map.put(msg, "tool_calls", Enum.map(uses, &encode_tool_call/1))
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

        blocks ->
          images = extract_images(blocks)
          text = extract_text_content(blocks)

          msg = %{"role" => "user", "content" => text}
          msg = if images != [], do: Map.put(msg, "images", images), else: msg
          [msg]
      end

    tool_msgs ++ user_msg
  end

  defp split_assistant_content(content) do
    Enum.reduce(content, {[], [], []}, fn
      %Text{} = t, {texts, tools, thinks} -> {[t | texts], tools, thinks}
      %ToolUse{} = tu, {texts, tools, thinks} -> {texts, [tu | tools], thinks}
      %Thinking{} = th, {texts, tools, thinks} -> {texts, tools, [th | thinks]}
      _other, acc -> acc
    end)
    |> then(fn {texts, tools, thinks} ->
      {Enum.reverse(texts), Enum.reverse(tools), Enum.reverse(thinks)}
    end)
  end

  defp extract_images(blocks) do
    Enum.flat_map(blocks, fn
      %Attachment{source: {:base64, data}, media_type: "image/" <> _} -> [data]
      _ -> []
    end)
  end

  defp extract_text_content(blocks) do
    blocks
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  # Tool call encoding (assistant messages)

  defp encode_tool_call(%ToolUse{id: id, name: name, input: input}) do
    %{
      "function" => %{
        "name" => name,
        "arguments" => input
      }
    }
    |> maybe_put("id", id)
  end

  # Tool result encoding (separate "tool" role messages)

  defp encode_tool_result(%ToolResult{content: content}) do
    text =
      content
      |> Enum.filter(&match?(%Text{}, &1))
      |> Enum.map_join("", & &1.text)

    %{"role" => "tool", "content" => text}
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

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_stop_reason("stop"), do: :stop
  defp normalize_stop_reason("length"), do: :length
  defp normalize_stop_reason(_), do: :stop
end
