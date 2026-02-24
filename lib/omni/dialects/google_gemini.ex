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

  - No `:tool_use_delta` events — Google sends function call args complete
    (as a map), not as streamed JSON fragments. The `:block_start` for
    tool_use carries the full input directly.
  - Cache option is a no-op (Google uses server-side caching, incompatible
    model)
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  @impl true
  def option_schema, do: %{}

  @impl true
  def handle_path(%Model{id: model_id}, _opts) do
    "/v1beta/models/#{model_id}:streamGenerateContent?alt=sse"
  end

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body =
      %{
        "contents" => encode_messages(context.messages),
        "generationConfig" => build_generation_config(opts)
      }
      |> maybe_put_system(context.system)
      |> maybe_put_tools(context.tools)
      |> maybe_put_thinking(model, opts[:thinking])

    body
  end

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body
  defp maybe_put_thinking(body, _model, false), do: body
  defp maybe_put_thinking(body, _model, :none), do: body
  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body

  defp maybe_put_thinking(body, _model, thinking) do
    thinking_config =
      case normalize_thinking(thinking) do
        {:effort, level} ->
          %{"thinkingLevel" => level_string(level), "includeThoughts" => true}

        {:effort, _level, budget} ->
          %{"thinkingBudget" => budget, "includeThoughts" => true}
      end

    Map.update!(body, "generationConfig", &Map.put(&1, "thinkingConfig", thinking_config))
  end

  defp level_string(:low), do: "low"
  defp level_string(:medium), do: "medium"
  defp level_string(:high), do: "high"
  defp level_string(:max), do: "high"

  defp normalize_thinking(true), do: {:effort, :high}
  defp normalize_thinking(level) when level in [:low, :medium, :high, :max], do: {:effort, level}

  defp normalize_thinking(opts) when is_list(opts) do
    {:effort, Keyword.get(opts, :effort, :high), Keyword.get(opts, :budget)}
  end

  # Parse events — Google sends `GenerateContentResponse` objects.
  # Each event is decomposed into envelope (:message) + content (:block_delta/:block_start).

  @impl true
  def handle_event(event) do
    message = extract_message(event)
    content = extract_content(event)

    case message do
      data when data == %{} -> []
      data -> [{:message, data}]
    end ++ content
  end

  defp extract_message(event) do
    %{}
    |> maybe_put_model(event)
    |> maybe_put_stop_reason(event)
    |> maybe_put_usage(event)
  end

  defp maybe_put_model(map, %{"modelVersion" => model_id}), do: Map.put(map, :model, model_id)
  defp maybe_put_model(map, _), do: map

  defp maybe_put_stop_reason(map, %{"candidates" => [%{"finishReason" => reason} | _]})
       when is_binary(reason) do
    Map.put(map, :stop_reason, normalize_stop_reason(reason))
  end

  defp maybe_put_stop_reason(map, _), do: map

  defp maybe_put_usage(map, %{"usageMetadata" => usage}),
    do: Map.put(map, :usage, normalize_usage(usage))

  defp maybe_put_usage(map, _), do: map

  defp extract_content(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    Enum.flat_map(parts, &parse_part/1)
  end

  defp extract_content(_), do: []

  # Google sends function calls either as multiple parts in one event or as
  # separate events with one part each. In both cases every block_start needs
  # a globally unique index so StreamingResponse doesn't merge them into a
  # single block. A monotonic unique integer guarantees uniqueness across events.
  defp parse_part(%{
         "functionCall" => %{"name" => name, "args" => args},
         "thoughtSignature" => sig
       }) do
    [
      {:block_start,
       %{
         type: :tool_use,
         index: System.unique_integer([:positive, :monotonic]),
         id: "google_fc_#{System.unique_integer([:positive])}",
         name: name,
         input: args,
         signature: sig
       }}
    ]
  end

  defp parse_part(%{"functionCall" => %{"name" => name, "args" => args}}) do
    [
      {:block_start,
       %{
         type: :tool_use,
         index: System.unique_integer([:positive, :monotonic]),
         id: "google_fc_#{System.unique_integer([:positive])}",
         name: name,
         input: args
       }}
    ]
  end

  defp parse_part(%{"text" => text, "thought" => true, "thoughtSignature" => sig})
       when is_binary(text) and text != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: text, signature: sig}}]
  end

  defp parse_part(%{"text" => text, "thought" => true}) when is_binary(text) and text != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: text}}]
  end

  defp parse_part(%{"text" => text, "thoughtSignature" => sig})
       when is_binary(text) and text != "" do
    [{:block_delta, %{type: :text, index: 0, delta: text, signature: sig}}]
  end

  defp parse_part(%{"text" => text}) when is_binary(text) and text != "" do
    [{:block_delta, %{type: :text, index: 0, delta: text}}]
  end

  defp parse_part(_), do: []

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

  defp encode_part(%Text{text: text, signature: sig}) do
    part = %{"text" => text}
    part = if sig, do: Map.put(part, "thoughtSignature", sig), else: part
    [part]
  end

  defp encode_part(%Attachment{source: {:base64, data}, media_type: mt}) do
    [%{"inlineData" => %{"mimeType" => mt, "data" => data}}]
  end

  defp encode_part(%Attachment{source: {:url, url}, media_type: mt}) do
    [%{"fileData" => %{"fileUri" => url, "mimeType" => mt}}]
  end

  defp encode_part(%ToolUse{name: name, input: args, signature: sig}) do
    part = %{"functionCall" => %{"name" => name, "args" => args}}
    part = if sig, do: Map.put(part, "thoughtSignature", sig), else: part
    [part]
  end

  defp encode_part(%ToolResult{name: name, content: content}) do
    text =
      content
      |> Enum.filter(&match?(%Text{}, &1))
      |> Enum.map_join("", & &1.text)

    [%{"functionResponse" => %{"name" => name, "response" => %{"result" => text}}}]
  end

  defp encode_part(%Thinking{text: text, signature: sig}) when is_binary(text) do
    part = %{"text" => text, "thought" => true}
    part = if sig, do: Map.put(part, "thoughtSignature", sig), else: part
    [part]
  end

  defp encode_part(%Thinking{text: nil, signature: sig}) when is_binary(sig) do
    [%{"thoughtSignature" => sig}]
  end

  defp encode_part(%Thinking{}), do: []

  # Generation config

  defp build_generation_config(opts) do
    %{}
    |> maybe_put("maxOutputTokens", opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
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

  # Usage normalization

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
