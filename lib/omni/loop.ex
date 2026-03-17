defmodule Omni.Loop do
  # Recursive request loop for LLM interactions.
  #
  # Handles two kinds of multi-step loops within a single lazy stream pipeline:
  #
  # 1. Tool auto-execution — when the model produces tool use blocks, executes
  #    tools via Tool.Runner, feeds results back, and streams the next step.
  #    Controlled by :max_steps option. Breaks when any tool has no handler
  #    (schema-only). Hallucinated tool names produce error results sent back
  #    to the model, and the loop continues.
  #
  # 2. Structured output validation — when :output schema is set, validates the
  #    final response text (JSON decode + Peri validation) and retries up to
  #    @max_output_retries times on failure. Skips retry on :length stop reason.
  #
  # Both use recursive Stream.flat_map — each step's StreamingResponse events
  # pass through to the consumer, and when :done arrives, the flat_map callback
  # returns either a terminal event or a new lazy stream for the next step.
  @moduledoc false

  alias Omni.{
    Context,
    Message,
    Model,
    Request,
    Response,
    Schema,
    StreamingResponse,
    Tool,
    Turn,
    Usage
  }

  alias Omni.Content.{Text, ToolUse}

  @max_output_retries 3

  @doc """
  Builds and executes a streaming request with automatic tool looping.

  Always executes at least one request. After each step, checks whether to
  loop based on tool use blocks in the response. The result is a single
  `StreamingResponse` whose stream lazily concatenates all steps.
  """
  @spec stream(Model.t(), Context.t(), keyword()) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream(model, context, opts) do
    {raw?, opts} = Keyword.pop(opts, :raw, false)
    {max_steps, opts} = Keyword.pop(opts, :max_steps, :infinity)
    {tool_timeout, opts} = Keyword.pop(opts, :tool_timeout, 30_000)
    {turn_id, opts} = Keyword.pop(opts, :turn_id, 0)
    {turn_parent, opts} = Keyword.pop(opts, :turn_parent, nil)
    cancel_ref = make_ref()

    state = %{
      model: model,
      context: context,
      opts: opts,
      raw?: raw?,
      max_steps: max_steps,
      tool_timeout: tool_timeout,
      step_num: 1,
      cancel_ref: cancel_ref,
      tool_map: build_tool_map(context.tools),
      messages: [],
      raws: [],
      usage: %Usage{},
      output_schema: opts[:output],
      output_retries: 0,
      turn_id: turn_id,
      turn_parent: turn_parent
    }

    with {:ok, sr} <- step(state) do
      Process.put(cancel_ref, sr.cancel)

      stream = loop_stream(sr, state)

      cancel = fn ->
        case Process.delete(cancel_ref) do
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
    Stream.flat_map(sr.stream, fn
      {:done, _data, response} ->
        handle_step_result(response, state)

      {:error, _, _} = event ->
        finish(state, [event])

      event ->
        [event]
    end)
  end

  # -- Step result handling --

  defp handle_step_result(response, state) do
    tool_uses = extract_tool_uses(response.message.content)

    # Accumulate this step's data
    state = %{
      state
      | messages: state.messages ++ [response.message],
        usage: Usage.add(state.usage, response.turn.usage),
        raws: state.raws ++ (response.raw || [])
    }

    cond do
      should_loop?(tool_uses, response, state) ->
        do_loop(tool_uses, response, state)

      state.output_schema != nil ->
        handle_output_validation(response, state)

      true ->
        final_response = build_final_response(state, response)
        finish(state, [{:done, %{stop_reason: final_response.stop_reason}, final_response}])
    end
  end

  defp do_loop(tool_uses, response, state) do
    # Execute tools and build result blocks
    tool_results = Tool.Runner.run(tool_uses, state.tool_map, state.tool_timeout)
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
        Stream.concat(tool_result_events, finish(state, [{:error, reason, error_response}]))
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
        case Schema.validate(state.output_schema, decoded) do
          {:ok, validated} ->
            final_response = %{build_final_response(state, response) | output: validated}
            finish(state, [{:done, %{stop_reason: final_response.stop_reason}, final_response}])

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
    finish(state, [{:done, %{stop_reason: final_response.stop_reason}, final_response}])
  end

  defp retry_output(%{stop_reason: :length} = response, state, _kind, _errors) do
    final_response = build_final_response(state, response)
    finish(state, [{:done, %{stop_reason: final_response.stop_reason}, final_response}])
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
        finish(state, [{:error, reason, error_response}])
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
      {:tool_result, tr, response}
    end)
  end

  # -- Response building --

  defp build_final_response(state, last_step_response) do
    turn =
      Turn.new(
        id: state.turn_id,
        parent: state.turn_parent,
        messages: state.messages,
        usage: state.usage
      )

    %{
      last_step_response
      | turn: turn,
        raw: if(state.raw?, do: state.raws, else: nil)
    }
  end

  defp build_error_response(state, reason) do
    turn =
      Turn.new(
        id: state.turn_id,
        parent: state.turn_parent,
        messages: state.messages,
        usage: state.usage
      )

    Response.new(
      message: Message.new(role: :assistant, content: []),
      model: state.model,
      turn: turn,
      stop_reason: :error,
      error: reason
    )
  end

  # -- Cleanup --

  defp finish(state, events) do
    Process.delete(state.cancel_ref)
    events
  end

  # -- Helpers --

  defp extract_tool_uses(content) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn tool -> {tool.name, tool} end)
  end
end
