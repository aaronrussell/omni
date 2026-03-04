defmodule Omni.Dialects.GoogleGemini do
  @moduledoc """
  Dialect implementation for the Google Gemini wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.

  ## Notable differences

  - Model ID is embedded in the URL path, not the request body
  - No `:tool_use_delta` events — Gemini sends function call arguments
    complete rather than as streamed JSON fragments
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
      |> maybe_put_output(opts[:output])

    body
  end

  # Thinking

  defp maybe_put_thinking(body, _model, nil), do: body
  defp maybe_put_thinking(body, %Model{reasoning: false}, _thinking), do: body

  defp maybe_put_thinking(body, _model, false) do
    thinking_config = %{"thinkingBudget" => 0}
    Map.update!(body, "generationConfig", &Map.put(&1, "thinkingConfig", thinking_config))
  end

  defp maybe_put_thinking(body, _model, level) when is_atom(level) do
    thinking_config = %{"thinkingLevel" => level_string(level), "includeThoughts" => true}
    Map.update!(body, "generationConfig", &Map.put(&1, "thinkingConfig", thinking_config))
  end

  defp maybe_put_thinking(body, _model, %{budget: budget}) when is_integer(budget) do
    thinking_config = %{"thinkingBudget" => budget, "includeThoughts" => true}
    Map.update!(body, "generationConfig", &Map.put(&1, "thinkingConfig", thinking_config))
  end

  defp maybe_put_thinking(body, _model, %{} = opts) do
    level = Map.get(opts, :effort, :high)
    thinking_config = %{"thinkingLevel" => level_string(level), "includeThoughts" => true}
    Map.update!(body, "generationConfig", &Map.put(&1, "thinkingConfig", thinking_config))
  end

  defp level_string(:low), do: "low"
  defp level_string(:medium), do: "medium"
  defp level_string(:high), do: "high"
  defp level_string(:max), do: "high"

  # Output schema

  defp maybe_put_output(body, nil), do: body

  defp maybe_put_output(body, schema) do
    Map.update!(body, "generationConfig", fn config ->
      config
      |> Map.put("responseMimeType", "application/json")
      |> Map.put("responseSchema", schema)
    end)
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
  defp normalize_stop_reason("SAFETY"), do: :refusal
  defp normalize_stop_reason("RECITATION"), do: :refusal
  defp normalize_stop_reason("LANGUAGE"), do: :refusal
  defp normalize_stop_reason("BLOCKLIST"), do: :refusal
  defp normalize_stop_reason("PROHIBITED_CONTENT"), do: :refusal
  defp normalize_stop_reason("SPII"), do: :refusal
  defp normalize_stop_reason("IMAGE_SAFETY"), do: :refusal
  defp normalize_stop_reason(_), do: :stop
end
