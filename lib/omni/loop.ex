defmodule Omni.Loop do
  # Recursive request loop for LLM interactions.
  #
  # Handles two kinds of multi-step loops within a single lazy stream pipeline:
  #
  # 1. Tool auto-execution — when the model produces tool use blocks, executes
  #    tools via Tool.Runner, feeds results back, and streams the next step.
  #    Controlled by :max_steps option. Breaks when a tool has no handler
  #    (schema-only) or a hallucinated tool name produces an error result.
  #
  # 2. Structured output validation — when :output schema is set, validates the
  #    final response text (JSON decode + Peri validation) and retries up to
  #    @max_output_retries times on failure. Skips retry on :length stop reason.
  #
  # Both use recursive Stream.concat — each step's StreamingResponse is consumed,
  # its :done event captured (via process dictionary), and a lazy continuation
  # thunk decides whether to loop or emit the final :done.
  @moduledoc false

  alias Omni.{Context, Message, Model, Request, Response, Schema, StreamingResponse, Tool, Usage}
  alias Omni.Content.{Text, ToolResult, ToolUse}

  @max_output_retries 3

  @doc """
  Builds and executes a streaming request with automatic tool looping.

  Always executes at least one request. After each step, checks whether to
  loop based on tool use blocks in the response. The result is a single
  `StreamingResponse` whose stream lazily concatenates all steps.
  """
  @spec stream(Model.t(), Context.t(), keyword(), boolean(), pos_integer() | :infinity) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream(model, context, opts, raw?, max_steps) do
    cancel_ref = make_ref()

    state = %{
      model: model,
      context: context,
      opts: opts,
      raw?: raw?,
      max_steps: max_steps,
      step_num: 1,
      cancel_ref: cancel_ref,
      tool_map: build_tool_map(context.tools),
      messages: [],
      raws: [],
      usage: %Usage{},
      output_schema: opts[:output],
      output_peri: if(opts[:output], do: Schema.to_peri(opts[:output])),
      output_retries: 0
    }

    with {:ok, sr} <- step(state) do
      Process.put(cancel_ref, sr.cancel)

      stream = loop_stream(sr, state)

      cancel = fn ->
        case Process.get(cancel_ref) do
          nil -> :ok
          fun when is_function(fun) -> fun.()
          _ -> :ok
        end
      end

      {:ok, %StreamingResponse{stream: stream, cancel: cancel}}
    end
  end

  # -- Step execution --

  defp step(%{model: model, context: context, opts: opts, raw?: raw?}) do
    with {:ok, req} <- Request.build(model, context, opts) do
      Request.stream(req, model, raw: raw?)
    end
  end

  # -- Stream pipeline --

  defp loop_stream(sr, state) do
    done_key = make_ref()

    # Pass through all events except :done, which we capture
    step_events =
      Stream.flat_map(sr.stream, fn
        {:done, _data, response} ->
          Process.put(done_key, response)
          []

        event ->
          [event]
      end)

    # Lazy continuation — evaluates after step_events is exhausted
    continuation =
      Stream.flat_map([:_], fn :_ ->
        case Process.delete(done_key) do
          nil ->
            # Error occurred mid-stream; :error event already passed through
            []

          response ->
            handle_step_result(response, state)
        end
      end)

    Stream.concat(step_events, continuation)
  end

  # -- Step result handling --

  defp handle_step_result(response, state) do
    tool_uses = extract_tool_uses(response.message.content)

    # Accumulate this step's data
    state = %{
      state
      | messages: state.messages ++ [response.message],
        usage: Usage.add(state.usage, response.usage),
        raws: state.raws ++ (response.raw || [])
    }

    cond do
      should_loop?(tool_uses, response, state) ->
        do_loop(tool_uses, response, state)

      state.output_schema != nil ->
        handle_output_validation(response, state)

      true ->
        final_response = build_final_response(state, response)
        [{:done, %{stop_reason: final_response.stop_reason}, final_response}]
    end
  end

  defp do_loop(tool_uses, response, state) do
    # Execute tools and build result blocks
    tool_results = Tool.Runner.run(tool_uses, state.tool_map)
    tool_result_events = build_tool_result_events(tool_results, response)

    # Build user message with tool results, update context
    user_message = Message.new(role: :user, content: tool_results)

    state = %{
      state
      | messages: state.messages ++ [user_message],
        context: %{
          state.context
          | messages: state.context.messages ++ [response.message, user_message]
        },
        step_num: state.step_num + 1
    }

    case step(state) do
      {:ok, next_sr} ->
        Process.put(state.cancel_ref, next_sr.cancel)
        Stream.concat(tool_result_events, loop_stream(next_sr, state))

      {:error, reason} ->
        error_response = build_error_response(state, reason)
        Stream.concat(tool_result_events, [{:error, reason, error_response}])
    end
  end

  # -- Output validation --

  defp handle_output_validation(response, state) do
    text =
      response.message.content
      |> Enum.filter(&match?(%Text{}, &1))
      |> Enum.map_join("", & &1.text)

    case JSON.decode(text) do
      {:ok, decoded} ->
        case Peri.validate(state.output_peri, decoded) do
          {:ok, validated} ->
            final_response = %{build_final_response(state, response) | output: validated}
            [{:done, %{stop_reason: final_response.stop_reason}, final_response}]

          {:error, errors} ->
            retry_output(response, state, :validation, errors)
        end

      {:error, _} ->
        retry_output(response, state, :decode, nil)
    end
  end

  defp retry_output(response, state, _kind, _errors)
       when state.output_retries >= @max_output_retries do
    final_response = build_final_response(state, response)
    [{:done, %{stop_reason: final_response.stop_reason}, final_response}]
  end

  defp retry_output(%{stop_reason: :length} = response, state, _kind, _errors) do
    final_response = build_final_response(state, response)
    [{:done, %{stop_reason: final_response.stop_reason}, final_response}]
  end

  defp retry_output(response, state, kind, errors) do
    error_text =
      case kind do
        :decode ->
          "Your response was not valid JSON. Please respond with only valid JSON matching the required schema."

        :validation ->
          "Your JSON response did not match the required schema. Validation errors:\n" <>
            Schema.format_errors(errors)
      end

    user_message = Message.new(role: :user, content: error_text)

    state = %{
      state
      | messages: state.messages ++ [user_message],
        context: %{
          state.context
          | messages: state.context.messages ++ [response.message, user_message]
        },
        step_num: state.step_num + 1,
        output_retries: state.output_retries + 1
    }

    case step(state) do
      {:ok, next_sr} ->
        Process.put(state.cancel_ref, next_sr.cancel)
        loop_stream(next_sr, state)

      {:error, reason} ->
        error_response = build_error_response(state, reason)
        [{:error, reason, error_response}]
    end
  end

  # -- Loop control --

  defp should_loop?([], _response, _state), do: false

  defp should_loop?(tool_uses, response, state) do
    response.stop_reason == :tool_use and
      step_within_limit?(state) and
      all_executable?(tool_uses, state.tool_map)
  end

  defp step_within_limit?(%{max_steps: :infinity}), do: true
  defp step_within_limit?(%{step_num: n, max_steps: max}), do: n < max

  defp all_executable?(tool_uses, tool_map) do
    Enum.all?(tool_uses, fn tool_use ->
      case Map.get(tool_map, tool_use.name) do
        # Hallucinated name — not a reason to break, error result sent to model
        nil -> true
        # Schema-only tool (no handler) — break, user handles manually
        %Tool{handler: nil} -> false
        # Has handler — executable
        %Tool{} -> true
      end
    end)
  end

  # -- Event building --

  defp build_tool_result_events(tool_results, response) do
    Enum.map(tool_results, fn tr ->
      {:tool_result,
       %{
         name: tr.name,
         tool_use_id: tr.tool_use_id,
         output: tool_result_text(tr),
         is_error: tr.is_error
       }, response}
    end)
  end

  defp tool_result_text(%ToolResult{content: [%Text{text: text}]}), do: text
  defp tool_result_text(%ToolResult{content: []}), do: ""

  defp tool_result_text(%ToolResult{content: blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn %Text{text: text} -> text end)
  end

  # -- Response building --

  defp build_final_response(state, last_step_response) do
    %{
      last_step_response
      | messages: state.messages,
        usage: state.usage,
        raw: if(state.raw?, do: state.raws, else: nil)
    }
  end

  defp build_error_response(state, reason) do
    Response.new(
      message: Message.new(role: :assistant, content: []),
      model: state.model,
      usage: state.usage,
      stop_reason: :error,
      error: reason,
      messages: state.messages
    )
  end

  # -- Helpers --

  defp extract_tool_uses(content) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn tool -> {tool.name, tool} end)
  end
end
