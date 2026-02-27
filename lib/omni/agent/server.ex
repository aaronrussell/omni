defmodule Omni.Agent.Server do
  @moduledoc false

  use GenServer

  alias Omni.{Context, Message, Model, Response, Tool, Usage}
  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}

  def start_link(init_arg, gs_opts) do
    # Capture $callers so the chain reaches back to whoever started the agent.
    # GenServer doesn't propagate $callers like Task does, so without this,
    # process-ownership registries (Req.Test, Mox) in spawned step processes
    # can't trace back to the originating process.
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, {callers, init_arg}, gs_opts)
  end

  # -- Init --

  @impl GenServer
  def init({callers, {module, opts}}) do
    Process.put(:"$callers", callers)
    Process.flag(:trap_exit, true)

    with {:ok, model} <- resolve_model(opts[:model]),
         {:ok, assigns} <- call_init(module, opts) do
      context =
        Context.new(
          system: opts[:system],
          tools: opts[:tools] || []
        )

      state = %State{
        module: module,
        model: model,
        context: context,
        opts: Keyword.get(opts, :opts, []),
        assigns: assigns,
        listener: opts[:listener],
        tool_timeout: Keyword.get(opts, :tool_timeout, 5_000)
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_model({provider_id, model_id}), do: Model.get(provider_id, model_id)
  defp resolve_model(%Model{} = model), do: {:ok, model}
  defp resolve_model(nil), do: {:error, :missing_model}

  # -- Calls --

  @impl GenServer
  def handle_call({:prompt, content, opts}, {from_pid, _}, %{status: :idle} = state) do
    state = if state.listener == nil, do: %{state | listener: from_pid}, else: state

    user_message = Message.new(role: :user, content: content)
    prompt_opts = Keyword.merge(state.opts, opts)

    state = %{
      state
      | status: :running,
        step: 0,
        pending_messages: [user_message],
        prompt_opts: prompt_opts
    }

    state = spawn_step(state)
    {:reply, :ok, state}
  end

  def handle_call({:prompt, content, _opts}, _from, %{status: status} = state)
      when status in [:running, :paused] do
    {:reply, :ok, %{state | next_prompt: content}}
  end

  def handle_call({:resume, decision}, _from, %{status: :paused} = state) do
    %{tool_use: tool_use, remaining: remaining, approved: approved, tool_map: tool_map} =
      state.paused_decision

    state = %{state | status: :running, paused_decision: nil}

    {approved, state} =
      case decision do
        :approve ->
          {[tool_use | approved], state}

        {:reject, reason} ->
          result =
            ToolResult.new(
              tool_use_id: tool_use.id,
              name: tool_use.name,
              content: "Tool rejected: #{inspect(reason)}",
              is_error: true
            )

          {approved, %{state | rejected_results: state.rejected_results ++ [result]}}
      end

    state = process_next_tool_decision(remaining, approved, tool_map, state)
    {:reply, :ok, state}
  end

  def handle_call({:resume, _decision}, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  def handle_call({:add_tools, tools}, _from, %{status: :idle} = state) do
    context = %{state.context | tools: state.context.tools ++ tools}
    {:reply, :ok, %{state | context: context}}
  end

  def handle_call({:remove_tools, names}, _from, %{status: :idle} = state) do
    name_set = MapSet.new(names)
    tools = Enum.reject(state.context.tools, &MapSet.member?(name_set, &1.name))
    context = %{state.context | tools: tools}
    {:reply, :ok, %{state | context: context}}
  end

  def handle_call(:cancel, _from, %{status: status} = state) when status in [:running, :paused] do
    state = do_cancel(state)
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, %{status: :idle} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:clear, _from, %{status: :idle} = state) do
    state = %{
      state
      | context: %{state.context | messages: []},
        usage: %Usage{}
    }

    {:reply, :ok, state}
  end

  def handle_call({:listen, pid}, _from, %{status: :idle} = state) do
    {:reply, :ok, %{state | listener: pid}}
  end

  # Catch-all for mutating ops while running or paused
  def handle_call({op, _}, _from, state) when op in [:add_tools, :remove_tools, :listen] do
    {:reply, {:error, :running}, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, {:error, :running}, state}
  end

  def handle_call(:get_model, _from, state), do: {:reply, state.model, state}
  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}
  def handle_call(:get_status, _from, state), do: {:reply, state.status, state}
  def handle_call(:get_assigns, _from, state), do: {:reply, state.assigns, state}
  def handle_call(:get_usage, _from, state), do: {:reply, state.usage, state}

  # -- Info (step messages) --

  @impl GenServer
  def handle_info({ref, {:event, type, event_map}}, %{step_task: {_, ref}} = state) do
    notify(state, type, event_map)
    {:noreply, state}
  end

  def handle_info({ref, {:complete, %Response{} = response}}, %{step_task: {_, ref}} = state) do
    state = handle_step_complete(response, state)
    {:noreply, state}
  end

  def handle_info({ref, {:error, reason}}, %{step_task: {_, ref}} = state) do
    state = %{state | step_task: nil}

    case call_handle_error(state.module, reason, state) do
      {:retry, new_state} ->
        {:noreply, spawn_step(new_state)}

      {:stop, new_state} ->
        new_state = reset_round(new_state)
        notify(new_state, :error, reason)
        {:noreply, new_state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{step_task: {pid, _}} = state)
      when reason not in [:normal, :killed] do
    error = {:step_crashed, reason}
    state = %{state | step_task: nil}

    case call_handle_error(state.module, error, state) do
      {:retry, new_state} ->
        {:noreply, spawn_step(new_state)}

      {:stop, new_state} ->
        new_state = reset_round(new_state)
        notify(new_state, :error, error)
        {:noreply, new_state}
    end
  end

  # -- Info (executor messages) --

  def handle_info({ref, {:tools_executed, results}}, %{executor_task: {_, ref}} = state) do
    state = handle_tools_executed(results, state)
    {:noreply, state}
  end

  def handle_info({ref, {:executor_error, reason}}, %{executor_task: {_, ref}} = state) do
    state = reset_round(state)
    notify(state, :error, {:executor_error, reason})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{executor_task: {pid, _}} = state)
      when reason not in [:normal, :killed] do
    state = reset_round(state)
    notify(state, :error, {:executor_crashed, reason})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Terminate --

  @impl GenServer
  def terminate(reason, state) do
    call_terminate(state.module, reason, state)
  end

  # -- Step execution --

  defp spawn_step(state) do
    full_context = %{state.context | messages: state.context.messages ++ state.pending_messages}
    opts = Keyword.merge(state.prompt_opts, max_steps: 1)
    ref = make_ref()

    {:ok, pid} = Omni.Agent.Step.start_link(self(), ref, state.model, full_context, opts)

    %{state | step_task: {pid, ref}, step: state.step + 1}
  end

  # -- Step completion --

  defp handle_step_complete(response, state) do
    pending = state.pending_messages ++ [response.message]
    usage = Usage.add(state.usage, response.usage)

    state = %{
      state
      | pending_messages: pending,
        usage: usage,
        step_task: nil,
        last_response: response
    }

    tool_uses = extract_tool_uses(response.message.content)

    if tool_uses != [] and all_executable?(tool_uses, state.context.tools) do
      handle_tool_decision_phase(tool_uses, state)
    else
      finalize_turn(response, state)
    end
  end

  # -- Tool decision phase --

  defp handle_tool_decision_phase(tool_uses, state) do
    tool_map = build_tool_map(state.context.tools)
    process_next_tool_decision(tool_uses, [], tool_map, state)
  end

  defp process_next_tool_decision([], approved, tool_map, state) do
    approved = Enum.reverse(approved)

    if approved == [] do
      handle_tools_executed([], state)
    else
      spawn_executor(approved, tool_map, state)
    end
  end

  defp process_next_tool_decision([tool_use | rest], approved, tool_map, state) do
    case call_handle_tool_call(state.module, tool_use, state) do
      {:execute, new_state} ->
        process_next_tool_decision(rest, [tool_use | approved], tool_map, new_state)

      {:reject, reason, new_state} ->
        result =
          ToolResult.new(
            tool_use_id: tool_use.id,
            name: tool_use.name,
            content: "Tool rejected: #{inspect(reason)}",
            is_error: true
          )

        new_state = %{new_state | rejected_results: new_state.rejected_results ++ [result]}
        process_next_tool_decision(rest, approved, tool_map, new_state)

      {:pause, new_state} ->
        paused = %{
          tool_use: tool_use,
          remaining: rest,
          approved: approved,
          tool_map: tool_map
        }

        %{new_state | status: :paused, paused_decision: paused}
        |> tap(&notify(&1, :pause, tool_use))
    end
  end

  defp spawn_executor(approved_uses, tool_map, state) do
    ref = make_ref()

    {:ok, pid} =
      Omni.Agent.Executor.start_link(
        self(),
        ref,
        approved_uses,
        tool_map,
        state.tool_timeout
      )

    %{state | executor_task: {pid, ref}}
  end

  # -- Tool execution results --

  defp handle_tools_executed(executed_results, state) do
    # Merge rejected + executed results
    all_results = state.rejected_results ++ executed_results
    state = %{state | executor_task: nil, rejected_results: []}

    # Call handle_tool_result for each and notify listener
    {final_results, state} =
      Enum.map_reduce(all_results, state, fn result, st ->
        case call_handle_tool_result(st.module, result, st) do
          {:ok, final_result, new_state} ->
            notify(new_state, :tool_result, %{
              name: final_result.name,
              tool_use_id: final_result.tool_use_id,
              is_error: final_result.is_error
            })

            {final_result, new_state}
        end
      end)

    # Build user message with all tool results, append to pending
    user_message = Message.new(role: :user, content: final_results)
    state = %{state | pending_messages: state.pending_messages ++ [user_message]}

    if max_steps_reached?(state) do
      finalize_turn(state.last_response, state)
    else
      spawn_step(state)
    end
  end

  # -- Finalize turn --

  defp finalize_turn(response, state) do
    case call_handle_stop(state.module, response, state) do
      {:continue, prompt, new_state} ->
        cond do
          max_steps_reached?(new_state) ->
            commit_and_done(response, new_state)

          new_state.next_prompt != nil ->
            content = new_state.next_prompt
            new_state = %{new_state | next_prompt: nil}
            continue_turn(content, response, new_state)

          true ->
            continue_turn(prompt, response, new_state)
        end

      {:stop, new_state} ->
        cond do
          new_state.next_prompt != nil and not max_steps_reached?(new_state) ->
            content = new_state.next_prompt
            new_state = %{new_state | next_prompt: nil}
            continue_turn(content, response, new_state)

          true ->
            commit_and_done(response, new_state)
        end
    end
  end

  defp continue_turn(prompt, response, state) do
    notify(state, :turn, response)
    user_message = Message.new(role: :user, content: prompt)
    state = %{state | pending_messages: state.pending_messages ++ [user_message]}
    spawn_step(state)
  end

  defp commit_and_done(response, state) do
    context = %{state.context | messages: state.context.messages ++ state.pending_messages}

    %{
      state
      | context: context,
        status: :idle,
        step: 0,
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        pending_messages: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        paused_decision: nil
    }
    |> tap(&notify(&1, :done, response))
  end

  # -- Cancel --

  defp do_cancel(state) do
    kill_task(state.step_task)
    kill_task(state.executor_task)

    state
    |> reset_round()
    |> tap(&notify(&1, :cancelled, nil))
  end

  defp kill_task(nil), do: :ok
  defp kill_task({pid, _ref}), do: Process.exit(pid, :kill)

  # -- Helpers --

  defp reset_round(state) do
    %{
      state
      | status: :idle,
        step: 0,
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        pending_messages: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        paused_decision: nil
    }
  end

  defp max_steps_reached?(state) do
    max = Keyword.get(state.prompt_opts, :max_steps, :infinity)
    max != :infinity and state.step >= max
  end

  defp extract_tool_uses(content) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  defp all_executable?(tool_uses, tools) do
    tool_map = build_tool_map(tools)

    Enum.all?(tool_uses, fn tool_use ->
      case Map.get(tool_map, tool_use.name) do
        nil -> true
        %Tool{handler: nil} -> false
        %Tool{} -> true
      end
    end)
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn tool -> {tool.name, tool} end)
  end

  defp notify(%{listener: nil}, _type, _data), do: :ok
  defp notify(%{listener: pid}, type, data), do: send(pid, {:agent, self(), type, data})

  # -- Callback dispatch --

  defp call_init(nil, _opts), do: {:ok, %{}}
  defp call_init(module, opts), do: module.init(opts)

  defp call_handle_stop(nil, _response, state), do: {:stop, state}
  defp call_handle_stop(module, response, state), do: module.handle_stop(response, state)

  defp call_handle_tool_call(nil, _tool_use, state), do: {:execute, state}

  defp call_handle_tool_call(module, tool_use, state),
    do: module.handle_tool_call(tool_use, state)

  defp call_handle_tool_result(nil, result, state), do: {:ok, result, state}

  defp call_handle_tool_result(module, result, state),
    do: module.handle_tool_result(result, state)

  defp call_handle_error(nil, _error, state), do: {:stop, state}
  defp call_handle_error(module, error, state), do: module.handle_error(error, state)

  defp call_terminate(nil, _reason, _state), do: :ok
  defp call_terminate(module, reason, state), do: module.terminate(reason, state)
end
