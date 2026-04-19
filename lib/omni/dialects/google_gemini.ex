defmodule Omni.Dialects.GoogleGemini do
  @moduledoc """
  Dialect implementation for the Google Gemini wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.

  ## Options

  - `:beta` (boolean, default `false`) — when `true`, uses the `/v1beta/`
    API path instead of `/v1/`, enabling access to beta features

  ## Notable differences

  - Model ID is embedded in the URL path, not the request body
  - No `:tool_use_delta` events — Gemini sends function call arguments
    complete rather than as streamed JSON fragments
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Model}

  import Omni.Util, only: [maybe_put: 3, maybe_merge: 2]

  @impl true
  def option_schema do
    %{
      beta: {:boolean, {:default, false}}
    }
  end

  @impl true
  def handle_path(%Model{id: model_id}, opts) do
    v = if opts[:beta] || opts[:output], do: "v1beta", else: "v1"
    "/#{v}/models/#{model_id}:streamGenerateContent?alt=sse"
  end

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    body = %{
      "contents" => encode_messages(context.messages),
      "generationConfig" => build_generation_config(model, opts)
    }

    body
    |> maybe_put("systemInstruction", encode_system(context.system))
    |> maybe_put("tools", encode_tools(context.tools))
  end

  # Thinking
  #
  # Gemini 3 models use thinkingLevel with its own 4-level scale
  # (minimal/low/medium/high). Omni levels shift down so that :low → "minimal"
  # exposes the provider's floor and :xhigh/:max both cap at Gemini's "high".
  #
  # Gemini 2.5 (and older) models only accept thinkingBudget as an integer.
  # Levels map to token allowances; :max uses -1 (dynamic) to let the model
  # self-manage.

  defp encode_thinking(_model, nil), do: nil
  defp encode_thinking(%Model{reasoning: false}, _thinking), do: nil
  defp encode_thinking(_model, false), do: %{"thinkingConfig" => %{"thinkingBudget" => 0}}

  defp encode_thinking(model, level) when is_atom(level) do
    if gemini_3_model?(model) do
      %{"thinkingConfig" => %{"thinkingLevel" => gemini3_level(level), "includeThoughts" => true}}
    else
      %{
        "thinkingConfig" => %{
          "thinkingBudget" => level_to_budget(level),
          "includeThoughts" => true
        }
      }
    end
  end

  defp encode_thinking(_model, %{budget: budget}) when is_integer(budget) do
    %{"thinkingConfig" => %{"thinkingBudget" => budget, "includeThoughts" => true}}
  end

  defp encode_thinking(model, %{} = opts) do
    encode_thinking(model, Map.get(opts, :effort, :high))
  end

  defp gemini_3_model?(%Model{id: "gemini-3" <> _}), do: true
  defp gemini_3_model?(_), do: false

  defp gemini3_level(:low), do: "minimal"
  defp gemini3_level(:medium), do: "low"
  defp gemini3_level(:high), do: "medium"
  defp gemini3_level(:xhigh), do: "high"
  defp gemini3_level(:max), do: "high"

  defp level_to_budget(:low), do: 2048
  defp level_to_budget(:medium), do: 4096
  defp level_to_budget(:high), do: 8192
  defp level_to_budget(:xhigh), do: 16384
  # -1 enables Gemini's "dynamic thinking": the model picks a budget up to its
  # per-variant ceiling (Pro 32768, Flash/Lite 24576). Universal across 2.5.
  defp level_to_budget(:max), do: -1

  # Output schema

  defp encode_output(nil), do: nil

  defp encode_output(schema) do
    %{"responseMimeType" => "application/json", "responseSchema" => schema}
  end

  # Parse events — Google sends `GenerateContentResponse` objects.
  # Each event is decomposed into envelope (:message) + content (:block_delta/:block_start).

  @impl true
  def handle_event(%{"error" => %{"message" => message}}) do
    [{:error, message}]
  end

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
    |> maybe_put(:model, event["modelVersion"])
    |> maybe_put(:stop_reason, encode_stop_reason(event))
    |> maybe_put(:usage, normalize_usage(event["usageMetadata"]))
  end

  defp encode_stop_reason(%{"candidates" => [%{"finishReason" => reason} | _]})
       when is_binary(reason) do
    normalize_stop_reason(reason)
  end

  defp encode_stop_reason(_), do: nil

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

  defp encode_system(nil), do: nil
  defp encode_system(system), do: %{"parts" => [%{"text" => system}]}

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

  defp build_generation_config(model, opts) do
    %{}
    |> maybe_put("maxOutputTokens", opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
    |> maybe_merge(encode_thinking(model, opts[:thinking]))
    |> maybe_merge(encode_output(opts[:output]))
  end

  # Tool encoding

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    declarations = Enum.map(tools, &encode_tool/1)
    [%{"functionDeclarations" => declarations}]
  end

  defp encode_tool(%{name: name, description: description, input_schema: schema}) do
    %{"name" => name, "description" => description, "parameters" => schema}
  end

  # Usage normalization

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["promptTokenCount"],
      "output_tokens" => usage["candidatesTokenCount"]
    }
  end

  # Helpers

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
