defmodule Omni.Dialects.OpenAICompletions do
  @moduledoc """
  Dialect implementation for the OpenAI Chat Completions wire format.

  See `Omni.Dialect` for the behaviour specification and delta types.

  ## Compat flags

  The Chat Completions format is spoken by many providers, most with small
  deviations from OpenAI's own API. With no flags, the dialect behaves
  exactly like OpenAI's API; each flag describes one deviation. Set them on
  a provider's endpoint for this dialect,
  `dialects: %{Omni.Dialects.OpenAICompletions => [compat: [...]]}` (see
  `Omni.Provider`).

  | Flag | Default (OpenAI) | Setting it |
  |---|---|---|
  | `:max_tokens_field` | `"max_completion_tokens"` | sends `:max_tokens` under this field |
  | `:thinking_effort_field` | `"reasoning_effort"` | sends the effort level here (dots nest: `"reasoning.effort"`) |
  | `:thinking_budget_field` | no budget sent | sends a token budget here, for models that take one and list no effort values |
  | `:thinking_replay_format` | earlier reasoning not sent back | how reasoning is sent back on assistant messages (below) |
  | `:thinking_toggle_format` | off is `reasoning_effort: "none"`; no on-switch | how thinking is switched on and off (below) |
  | `:output_format` | `:json_schema` | `:json_object`: JSON mode, with the schema in the system prompt |
  | `:attachment_format` | `:file` | `:file_url`: non-image files as `file_url` content parts |
  | `:omit` | `[]` | never sends these: `:cache`, `:thinking`, `:strict_schema` |
  | `:extra_body` | `%{}` | merges these literal fields into every request body |

  `:thinking_toggle_format` values:

    * `:thinking_type` — `thinking: {type: "enabled" | "disabled"}`
    * `:enable_thinking` — `enable_thinking: true | false`
    * `:reasoning_enabled` — `reasoning: {enabled: true | false}`

  `:thinking_replay_format` values:

    * `:none` — reasoning is not sent back
    * `:reasoning_content` — sends the message's thinking text in a
      `reasoning_content` field on that assistant message
    * `:reasoning` — the same, in a `reasoning` field
    * `:reasoning_details` — captures `reasoning_details` from responses and
      sends them back on that assistant message
    * `:content_chunks` — sends the message's thinking as one leading
      `{type: "thinking", thinking: [{type: "text", ...}]}` part of a
      `content` array, before its text parts

  Models that list effort values (see `Omni.Model`) take the effort, even
  when a toggle format is set; the toggle switches them off, and switches on
  models without effort values. Likewise a budget is sent only to models
  without effort values.
  """

  @behaviour Omni.Dialect

  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Dialect, Model}

  import Omni.Util, only: [maybe_put: 3, put_path: 3]

  @image_media_types ~w(image/jpeg image/png image/gif image/webp)

  @impl true
  def option_schema, do: %{}

  @impl true
  def compat_schema do
    %{
      max_tokens_field: :string,
      thinking_effort_field: :string,
      thinking_budget_field: :string,
      thinking_replay_format:
        {:enum, [:none, :reasoning_content, :reasoning, :reasoning_details, :content_chunks]},
      thinking_toggle_format: {:enum, [:thinking_type, :enable_thinking, :reasoning_enabled]},
      output_format: {:enum, [:json_schema, :json_object]},
      attachment_format: {:enum, [:file, :file_url]},
      omit: {:list, {:enum, [:cache, :thinking, :strict_schema]}},
      extra_body: :map
    }
  end

  @impl true
  def auth, do: :bearer

  @impl true
  def handle_path(%Model{}, _opts), do: "/chat/completions"

  @impl true
  def handle_body(%Model{} = model, %Context{} = context, opts) do
    compat = Dialect.compat(model, __MODULE__)
    omit = Map.get(compat, :omit, [])

    body = %{
      "model" => model.id,
      "messages" => encode_messages(context.system, context.messages, compat),
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    body
    |> put_path(Map.get(compat, :max_tokens_field, "max_completion_tokens"), opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
    |> maybe_put("metadata", opts[:metadata])
    |> maybe_put("tools", encode_tools(context.tools))
    |> maybe_put("prompt_cache_retention", unless(:cache in omit, do: encode_cache(opts[:cache])))
    |> apply_thinking(model, unless(:thinking in omit, do: opts[:thinking]), compat)
    |> apply_output(opts[:output], compat)
    |> Map.merge(Map.get(compat, :extra_body, %{}))
  end

  # Thinking — the model's thinking data says what to send; compat flags say
  # how to spell it.

  defp apply_thinking(body, model, option, compat) do
    effort_field = Map.get(compat, :thinking_effort_field, "reasoning_effort")
    toggle = compat[:thinking_toggle_format]

    case Dialect.Thinking.resolve(model, option) do
      nil ->
        body

      :off when is_nil(toggle) ->
        put_path(body, effort_field, "none")

      :off ->
        put_toggle(body, toggle, false)

      %{effort: effort, level: level, budget: budget} ->
        cond do
          effort -> put_path(body, effort_field, effort)
          toggle -> put_toggle(body, toggle, true)
          true -> put_path(body, effort_field, effort_string(level))
        end
        # The effort is the model's own control; a budget beside it is
        # rejected (Alibaba), so only models without effort values get one.
        |> put_budget(compat[:thinking_budget_field], unless(effort, do: budget))
    end
  end

  defp put_toggle(body, :thinking_type, on?),
    do: Map.put(body, "thinking", %{"type" => if(on?, do: "enabled", else: "disabled")})

  defp put_toggle(body, :enable_thinking, on?), do: Map.put(body, "enable_thinking", on?)
  defp put_toggle(body, :reasoning_enabled, on?), do: put_path(body, "reasoning.enabled", on?)

  defp put_budget(body, nil, _budget), do: body
  defp put_budget(body, field, budget), do: put_path(body, field, budget)

  defp effort_string(:low), do: "low"
  defp effort_string(:medium), do: "medium"
  defp effort_string(:high), do: "high"
  defp effort_string(:xhigh), do: "xhigh"
  defp effort_string(:max), do: "xhigh"

  # Output schema

  defp apply_output(body, nil, _compat), do: body

  defp apply_output(body, schema, %{output_format: :json_object}) do
    instruction =
      "Respond with JSON matching this schema:\n```json\n" <>
        JSON.encode!(Omni.Schema.to_schema(schema)) <> "\n```"

    body
    |> Map.put("response_format", %{"type" => "json_object"})
    |> Map.update!("messages", &append_system(&1, instruction))
  end

  defp apply_output(body, schema, compat) do
    schema = schema |> Omni.Schema.to_schema() |> apply_strict()
    json_schema = %{"name" => "output", "schema" => schema}

    json_schema =
      if :strict_schema in Map.get(compat, :omit, []),
        do: json_schema,
        else: Map.put(json_schema, "strict", true)

    Map.put(body, "response_format", %{"type" => "json_schema", "json_schema" => json_schema})
  end

  defp apply_strict(%{type: "object"} = schema) do
    Omni.Schema.update(schema, additional_properties: false)
  end

  defp apply_strict(schema), do: schema

  defp append_system([%{"role" => "system"} = system | rest], instruction) do
    [Map.update!(system, "content", &(&1 <> "\n\n" <> instruction)) | rest]
  end

  defp append_system(messages, instruction) do
    [%{"role" => "system", "content" => instruction} | messages]
  end

  # Parse events — OpenAI sends homogeneous `chat.completion.chunk` objects.
  #
  # Parsing is tolerant: it accepts every known variant from any provider, with
  # no flags. Some servers (e.g. vLLM) pack multiple payload types into a
  # single chunk (tool_call args + finish_reason, reasoning + content). Each
  # field is extracted independently so nothing is silently dropped; deltas are
  # emitted before finish_reason so downstream accumulation sees the final
  # fragment before the block is finalized. The one flag read here is
  # thinking_replay_format, so replay data is captured only when it is sent back.

  @impl true
  def handle_event(%{"error" => %{"message" => message}}, _model), do: [{:error, message}]

  def handle_event(%{"choices" => [choice | _]} = event, model) do
    delta = choice["delta"] || %{}

    extract_start(delta, event) ++
      extract_tool_calls(delta) ++
      extract_reasoning(delta) ++
      extract_content(delta) ++
      extract_finish(choice, event) ++
      extract_replay(delta, Dialect.compat(model, __MODULE__))
  end

  def handle_event(%{"usage" => %{} = usage}, _model) do
    [{:message, %{usage: normalize_usage(usage)}}]
  end

  def handle_event(_, _model), do: []

  defp extract_start(delta, event) do
    if delta["role"] == "assistant" or has_tool_call_start?(delta) do
      case event do
        %{"model" => model_id} ->
          [{:message, maybe_put(%{model: model_id}, :usage, normalize_usage(event["usage"]))}]

        _ ->
          []
      end
    else
      []
    end
  end

  defp has_tool_call_start?(%{"tool_calls" => [_ | _] = tool_calls}),
    do: Enum.any?(tool_calls, &tool_call_start?/1)

  defp has_tool_call_start?(_), do: false

  defp tool_call_start?(%{"function" => %{"name" => name}}) when is_binary(name) and name != "",
    do: true

  defp tool_call_start?(_), do: false

  # Most servers stream one call per chunk; some pack several calls into one
  # delta's `tool_calls`. Mistral sends each call whole, without `index`, so
  # a call's position in the list stands in for it.
  defp extract_tool_calls(%{"tool_calls" => [_ | _] = tool_calls}) do
    tool_calls
    |> Enum.with_index()
    |> Enum.flat_map(fn {tc, position} -> extract_tool_call(tc, tc["index"] || position) end)
  end

  defp extract_tool_calls(_), do: []

  # A call starts with its name; continuation chunks carry none, or `""`
  # (GLM models on Mistral).
  defp extract_tool_call(tc, index) do
    args_delta =
      case encode_arguments(tc["function"]["arguments"]) do
        "" -> []
        args -> [{:block_delta, %{type: :tool_use, index: index, delta: args}}]
      end

    if tool_call_start?(tc) do
      start = %{type: :tool_use, index: index, id: tc["id"], name: tc["function"]["name"]}
      [{:block_start, start} | args_delta]
    else
      args_delta
    end
  end

  # Arguments are a JSON string fragment, or (Mistral) a whole JSON object.
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(args) when is_map(args), do: JSON.encode!(args)
  defp encode_arguments(_), do: ""

  defp extract_reasoning(%{"reasoning_content" => content})
       when is_binary(content) and content != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: content}}]
  end

  # Some servers send "reasoning" instead of "reasoning_content".
  defp extract_reasoning(%{"reasoning" => content})
       when is_binary(content) and content != "" do
    [{:block_delta, %{type: :thinking, index: 0, delta: content}}]
  end

  defp extract_reasoning(_), do: []

  defp extract_replay(%{"reasoning_details" => [_ | _] = details}, %{
         thinking_replay_format: :reasoning_details
       }) do
    [{:message, %{private: %{reasoning_details: details}}}]
  end

  defp extract_replay(_delta, _compat), do: []

  defp extract_content(%{"content" => content})
       when is_binary(content) and content != "" do
    [{:block_delta, %{type: :text, index: 0, delta: content}}]
  end

  # Mistral sends content as a list of chunks: thinking, then text.
  defp extract_content(%{"content" => [_ | _] = chunks}),
    do: Enum.flat_map(chunks, &extract_chunk/1)

  defp extract_content(_), do: []

  defp extract_chunk(%{"type" => "thinking", "thinking" => parts} = chunk) do
    deltas =
      for %{"type" => "text", "text" => text} <- List.wrap(parts),
          is_binary(text) and text != "",
          do: {:block_delta, %{type: :thinking, index: 0, delta: text}}

    case chunk["signature"] do
      sig when is_binary(sig) and sig != "" ->
        deltas ++ [{:block_delta, %{type: :thinking, index: 0, signature: sig}}]

      _ ->
        deltas
    end
  end

  defp extract_chunk(%{"type" => "text", "text" => text}) when is_binary(text) and text != "",
    do: [{:block_delta, %{type: :text, index: 0, delta: text}}]

  defp extract_chunk(_), do: []

  defp extract_finish(%{"finish_reason" => reason}, event) when is_binary(reason) do
    [
      {:message,
       maybe_put(
         %{stop_reason: normalize_stop_reason(reason)},
         :usage,
         normalize_usage(event["usage"])
       )}
    ]
  end

  defp extract_finish(_, _), do: []

  # Message encoding

  defp encode_messages(system, messages, compat) do
    system_msg =
      case system do
        nil -> []
        text -> [%{"role" => "system", "content" => text}]
      end

    system_msg ++ Enum.flat_map(messages, &encode_message(&1, compat))
  end

  defp encode_message(%{role: :assistant, content: content} = message, compat) do
    {thinking_blocks, text_blocks, tool_uses} = split_assistant_content(content)

    msg = %{"role" => "assistant"}

    msg =
      case encode_assistant_content(thinking_blocks, text_blocks, compat) do
        nil -> msg
        content -> Map.put(msg, "content", content)
      end

    msg =
      case tool_uses do
        [] -> msg
        uses -> Map.put(msg, "tool_calls", Enum.with_index(uses, &encode_tool_call/2))
      end

    [put_replay(msg, message, thinking_blocks, compat)]
  end

  defp encode_message(%{role: :user, content: content}, compat) do
    {tool_results, other_content} = Enum.split_with(content, &match?(%ToolResult{}, &1))

    tool_msgs = Enum.map(tool_results, &encode_tool_result/1)

    user_msg =
      case other_content do
        [] ->
          []

        [%Text{text: text}] ->
          [%{"role" => "user", "content" => text}]

        blocks ->
          [%{"role" => "user", "content" => Enum.map(blocks, &encode_content(&1, compat))}]
      end

    tool_msgs ++ user_msg
  end

  # With :content_chunks, thinking goes first as a single merged chunk
  # (Mistral rejects more than one leading thinking chunk) and text follows
  # as parts. Otherwise text is a plain string, and thinking goes in a field
  # (put_replay/4) or is dropped.
  defp encode_assistant_content(thinking, texts, %{thinking_replay_format: :content_chunks})
       when thinking != [] do
    [encode_thinking_chunk(thinking) | Enum.map(texts, &%{"type" => "text", "text" => &1.text})]
  end

  defp encode_assistant_content(_thinking, [], _compat), do: nil

  defp encode_assistant_content(_thinking, texts, _compat),
    do: Enum.map_join(texts, "", & &1.text)

  defp encode_thinking_chunk(blocks) do
    chunk = %{
      "type" => "thinking",
      "thinking" => [%{"type" => "text", "text" => Enum.map_join(blocks, "", & &1.text)}]
    }

    case blocks |> Enum.map(& &1.signature) |> Enum.reject(&is_nil/1) |> List.last() do
      nil -> chunk
      sig -> Map.put(chunk, "signature", sig)
    end
  end

  defp put_replay(msg, %{private: %{reasoning_details: [_ | _] = details}}, _thinking, %{
         thinking_replay_format: :reasoning_details
       }) do
    Map.put(msg, "reasoning_details", details)
  end

  defp put_replay(msg, _message, [_ | _] = thinking, %{thinking_replay_format: format})
       when format in [:reasoning_content, :reasoning] do
    Map.put(msg, Atom.to_string(format), Enum.map_join(thinking, "", & &1.text))
  end

  defp put_replay(msg, _message, _thinking, _compat), do: msg

  # Thinking without text (redacted, or an empty summary) is never sent back.
  defp split_assistant_content(content) do
    Enum.reduce(content, {[], [], []}, fn
      %Thinking{text: text} = th, {thinks, texts, tools} when is_binary(text) and text != "" ->
        {[th | thinks], texts, tools}

      %Text{} = t, {thinks, texts, tools} ->
        {thinks, [t | texts], tools}

      %ToolUse{} = tu, {thinks, texts, tools} ->
        {thinks, texts, [tu | tools]}

      _, acc ->
        acc
    end)
    |> then(fn {thinks, texts, tools} ->
      {Enum.reverse(thinks), Enum.reverse(texts), Enum.reverse(tools)}
    end)
  end

  # Content block encoding

  defp encode_content(%Text{text: text}, _compat), do: %{"type" => "text", "text" => text}

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt}, _compat)
       when mt in @image_media_types do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{mt};base64,#{data}"}}
  end

  defp encode_content(%Attachment{source: {:url, url}, media_type: mt}, _compat)
       when mt in @image_media_types do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp encode_content(
         %Attachment{source: {:base64, data}, media_type: mt},
         %{attachment_format: :file_url}
       ) do
    %{"type" => "file_url", "file_url" => %{"url" => "data:#{mt};base64,#{data}"}}
  end

  defp encode_content(%Attachment{source: {:base64, data}, media_type: mt}, _compat) do
    %{"type" => "file", "file" => %{"file_data" => "data:#{mt};base64,#{data}"}}
  end

  # Chat Completions has no generic URL content type — "image_url" is the only
  # URL-based input the API accepts. Non-image URLs (e.g. PDFs) work through
  # this wrapper on providers that support them.
  defp encode_content(%Attachment{source: {:url, url}}, _compat) do
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
        "parameters" => Omni.Schema.to_schema(schema)
      }
    }
  end

  # Cache control

  defp encode_cache(:long), do: "24h"
  defp encode_cache(_), do: nil

  # Usage normalization

  defp normalize_usage(nil), do: nil

  # `prompt_tokens` includes cached tokens; Omni's `input_tokens` doesn't.
  # Some servers (Together) report the cached count flat on `usage`.
  defp normalize_usage(usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || usage["cached_tokens"]

    %{}
    |> maybe_put("input_tokens", uncached(usage["prompt_tokens"], cached))
    |> maybe_put("output_tokens", usage["completion_tokens"])
    |> maybe_put("cache_read_tokens", cached)
  end

  defp uncached(nil, _cached), do: nil
  defp uncached(input, cached), do: input - (cached || 0)

  # Helpers

  defp normalize_stop_reason("stop"), do: :stop
  defp normalize_stop_reason("length"), do: :length
  defp normalize_stop_reason("tool_calls"), do: :tool_use
  defp normalize_stop_reason("content_filter"), do: :refusal
  defp normalize_stop_reason("function_call"), do: :tool_use

  # Mistral
  defp normalize_stop_reason("model_length"), do: :length
  defp normalize_stop_reason("error"), do: :error

  # Together
  defp normalize_stop_reason("eos"), do: :stop

  # Non-standard finish_reason values seen in the wild (GLM models), kept in
  # the one union table.
  defp normalize_stop_reason("sensitive"), do: :refusal
  defp normalize_stop_reason("model_context_window_exceeded"), do: :length
  defp normalize_stop_reason("network_error"), do: :error

  defp normalize_stop_reason(_), do: :stop
end
