defmodule Omni.Agent.Server do
  @moduledoc false

  # Lifecycle: round > turn > step
  #
  #   prompt/3 ──► ROUND START
  #   │
  #   ├─ Turn 1
  #   │   ├─ Step 1: spawn_step ──► LLM request ──► handle_step_complete
  #   │   │   └─ tool_use? ──► handle_tool_decision_phase ──► spawn_executor
  #   │   ├─ Step 2: spawn_step ──► LLM request ──► handle_step_complete
  #   │   │   └─ tool_use? ──► ...repeat...
  #   │   └─ Step N: no tool_use ──► finalize_turn ──► handle_stop
  #   │       └─ {:continue, prompt} ──► :turn event
  #   │
  #   ├─ Turn 2 (same structure)
  #   │   └─ ...
  #   │
  #   └─ Final turn: handle_stop returns {:stop, _}
  #       └─ commit_and_done ──► :done event ──► ROUND END

  use GenServer

  alias Omni.{Context, Message, Model, Response, Tool, Usage}
  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}

  @type t :: %__MODULE__{}

  defstruct [
    # Public state (passed to callbacks)
    :state,

    # Configuration (set at init, stable across rounds)
    :module,
    :listener,
    :tool_timeout,

    # Round lifecycle (set when a prompt starts, cleared by reset_round)
    pending_messages: [],
    prompt_opts: [],
    next_prompt: nil,
    last_response: nil,

    # Process tracking
    step_task: nil,
    executor_task: nil,

    # Tool decision phase (set when tool decisions begin, cleared by reset_round)
    tool_map: nil,
    approved_uses: [],
    remaining_uses: [],
    rejected_results: [],
    paused_use: nil
  ]

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

      agent_state = %State{
        model: model,
        context: context,
        opts: Keyword.get(opts, :opts, []),
        assigns: assigns
      }

      server = %__MODULE__{
        state: agent_state,
        module: module,
        listener: opts[:listener],
        tool_timeout: Keyword.get(opts, :tool_timeout, 5_000)
      }

      {:ok, server}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_model({provider_id, model_id}), do: Model.get(provider_id, model_id)
  defp resolve_model(%Model{} = model), do: {:ok, model}
  defp resolve_model(nil), do: {:error, :missing_model}

  # -- Calls --

  @impl GenServer
  def handle_call(
        {:prompt, content, opts},
        {from_pid, _},
        %__MODULE__{state: %{status: :idle}} = server
      ) do
    server = if server.listener == nil, do: %{server | listener: from_pid}, else: server

    user_message = Message.new(role: :user, content: content)
    prompt_opts = Keyword.merge(server.state.opts, opts)

    server = %{
      server
      | state: %{server.state | status: :running, step: 0},
        pending_messages: [user_message],
        prompt_opts: prompt_opts
    }

    server = spawn_step(server)
    {:reply, :ok, server}
  end

  def handle_call(
        {:prompt, content, _opts},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:running, :paused] do
    {:reply, :ok, %{server | next_prompt: content}}
  end

  def handle_call({:resume, decision}, _from, %__MODULE__{state: %{status: :paused}} = server) do
    tool_use = server.paused_use
    server = %{server | state: %{server.state | status: :running}, paused_use: nil}

    server =
      case decision do
        :approve ->
          %{server | approved_uses: [tool_use | server.approved_uses]}

        {:reject, reason} ->
          result =
            ToolResult.new(
              tool_use_id: tool_use.id,
              name: tool_use.name,
              content: "Tool rejected: #{inspect(reason)}",
              is_error: true
            )

          %{server | rejected_results: server.rejected_results ++ [result]}
      end

    server = process_next_tool_decision(server)
    {:reply, :ok, server}
  end

  def handle_call({:resume, _decision}, _from, server) do
    {:reply, {:error, :not_paused}, server}
  end

  def handle_call({:add_tools, tools}, _from, %__MODULE__{state: %{status: :idle}} = server) do
    context = %{server.state.context | tools: server.state.context.tools ++ tools}
    {:reply, :ok, %{server | state: %{server.state | context: context}}}
  end

  def handle_call({:remove_tools, names}, _from, %__MODULE__{state: %{status: :idle}} = server) do
    name_set = MapSet.new(names)
    tools = Enum.reject(server.state.context.tools, &MapSet.member?(name_set, &1.name))
    context = %{server.state.context | tools: tools}
    {:reply, :ok, %{server | state: %{server.state | context: context}}}
  end

  def handle_call(:cancel, _from, %__MODULE__{state: %{status: status}} = server)
      when status in [:running, :paused] do
    server = do_cancel(server)
    {:reply, :ok, server}
  end

  def handle_call(:cancel, _from, %__MODULE__{state: %{status: :idle}} = server) do
    {:reply, {:error, :idle}, server}
  end

  def handle_call(:clear, _from, %__MODULE__{state: %{status: :idle}} = server) do
    new_state = %{
      server.state
      | context: %{server.state.context | messages: []},
        usage: %Usage{}
    }

    {:reply, :ok, %{server | state: new_state}}
  end

  def handle_call({:listen, pid}, _from, %__MODULE__{state: %{status: :idle}} = server) do
    {:reply, :ok, %{server | listener: pid}}
  end

  # Catch-all for mutating ops while running or paused
  def handle_call({op, _}, _from, server) when op in [:add_tools, :remove_tools, :listen] do
    {:reply, {:error, :running}, server}
  end

  def handle_call(:clear, _from, server) do
    {:reply, {:error, :running}, server}
  end

  def handle_call(:get_model, _from, server), do: {:reply, server.state.model, server}
  def handle_call(:get_context, _from, server), do: {:reply, server.state.context, server}
  def handle_call(:get_status, _from, server), do: {:reply, server.state.status, server}
  def handle_call(:get_assigns, _from, server), do: {:reply, server.state.assigns, server}
  def handle_call(:get_usage, _from, server), do: {:reply, server.state.usage, server}

  # -- Info (step messages) --

  @impl GenServer
  def handle_info({ref, {:event, type, event_map}}, %{step_task: {_, ref}} = server) do
    notify(server, type, event_map)
    {:noreply, server}
  end

  def handle_info({ref, {:complete, %Response{} = response}}, %{step_task: {_, ref}} = server) do
    server = handle_step_complete(response, server)
    {:noreply, server}
  end

  def handle_info({ref, {:error, reason}}, %{step_task: {_, ref}} = server) do
    server = %{server | step_task: nil}

    case call_handle_error(server.module, reason, server.state) do
      {:retry, new_state} ->
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = reset_round(%{server | state: new_state})
        notify(server, :error, reason)
        {:noreply, server}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{step_task: {pid, _}} = server)
      when reason not in [:normal, :killed] do
    error = {:step_crashed, reason}
    server = %{server | step_task: nil}

    case call_handle_error(server.module, error, server.state) do
      {:retry, new_state} ->
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = reset_round(%{server | state: new_state})
        notify(server, :error, error)
        {:noreply, server}
    end
  end

  # -- Info (executor messages) --

  def handle_info({ref, {:tools_executed, results}}, %{executor_task: {_, ref}} = server) do
    server = handle_tools_executed(results, server)
    {:noreply, server}
  end

  def handle_info({ref, {:executor_error, reason}}, %{executor_task: {_, ref}} = server) do
    server = reset_round(server)
    notify(server, :error, {:executor_error, reason})
    {:noreply, server}
  end

  def handle_info({:EXIT, pid, reason}, %{executor_task: {pid, _}} = server)
      when reason not in [:normal, :killed] do
    server = reset_round(server)
    notify(server, :error, {:executor_crashed, reason})
    {:noreply, server}
  end

  def handle_info(_msg, server) do
    {:noreply, server}
  end

  # -- Terminate --

  @impl GenServer
  def terminate(reason, server) do
    call_terminate(server.module, reason, server.state)
  end

  # -- Step execution --

  defp spawn_step(server) do
    full_context = Context.push(server.state.context, server.pending_messages)

    opts = Keyword.merge(server.prompt_opts, max_steps: 1)
    ref = make_ref()

    {:ok, pid} = Omni.Agent.Step.start_link(self(), ref, server.state.model, full_context, opts)

    step = server.state.step + 1
    %{server | step_task: {pid, ref}, state: %{server.state | step: step}}
  end

  # -- Step completion --

  defp handle_step_complete(response, server) do
    pending = server.pending_messages ++ [response.message]
    usage = Usage.add(server.state.usage, response.usage)

    server = %{
      server
      | pending_messages: pending,
        step_task: nil,
        last_response: response,
        state: %{server.state | usage: usage}
    }

    tool_uses = extract_tool_uses(response.message.content)

    if tool_uses != [] and all_executable?(tool_uses, server.state.context.tools) do
      handle_tool_decision_phase(tool_uses, server)
    else
      finalize_turn(response, server)
    end
  end

  # -- Tool decision phase --

  defp handle_tool_decision_phase(tool_uses, server) do
    tool_map = build_tool_map(server.state.context.tools)

    %{server | tool_map: tool_map, remaining_uses: tool_uses, approved_uses: []}
    |> process_next_tool_decision()
  end

  defp process_next_tool_decision(%{remaining_uses: []} = server) do
    approved = Enum.reverse(server.approved_uses)

    if approved == [] do
      handle_tools_executed([], server)
    else
      spawn_executor(approved, server)
    end
  end

  defp process_next_tool_decision(%{remaining_uses: [tool_use | rest]} = server) do
    server = %{server | remaining_uses: rest}

    case call_handle_tool_call(server.module, tool_use, server.state) do
      {:execute, new_state} ->
        %{server | state: new_state, approved_uses: [tool_use | server.approved_uses]}
        |> process_next_tool_decision()

      {:reject, reason, new_state} ->
        result =
          ToolResult.new(
            tool_use_id: tool_use.id,
            name: tool_use.name,
            content: "Tool rejected: #{inspect(reason)}",
            is_error: true
          )

        %{server | state: new_state, rejected_results: server.rejected_results ++ [result]}
        |> process_next_tool_decision()

      {:pause, new_state} ->
        %{server | state: %{new_state | status: :paused}, paused_use: tool_use}
        |> tap(&notify(&1, :pause, tool_use))
    end
  end

  defp spawn_executor(approved_uses, server) do
    ref = make_ref()

    {:ok, pid} =
      Omni.Agent.Executor.start_link(
        self(),
        ref,
        approved_uses,
        server.tool_map,
        server.tool_timeout
      )

    %{server | executor_task: {pid, ref}}
  end

  # -- Tool execution results --

  defp handle_tools_executed(executed_results, server) do
    # Merge rejected + executed results
    all_results = server.rejected_results ++ executed_results
    server = %{server | executor_task: nil, rejected_results: []}

    # Call handle_tool_result for each and notify listener
    {final_results, server} =
      Enum.map_reduce(all_results, server, fn result, srv ->
        case call_handle_tool_result(srv.module, result, srv.state) do
          {:ok, final_result, new_state} ->
            srv = %{srv | state: new_state}

            notify(srv, :tool_result, %{
              name: final_result.name,
              tool_use_id: final_result.tool_use_id,
              is_error: final_result.is_error
            })

            {final_result, srv}
        end
      end)

    # Build user message with all tool results, append to pending
    user_message = Message.new(role: :user, content: final_results)
    server = %{server | pending_messages: server.pending_messages ++ [user_message]}

    if max_steps_reached?(server) do
      finalize_turn(server.last_response, server)
    else
      spawn_step(server)
    end
  end

  # -- Finalize turn --

  defp finalize_turn(response, server) do
    case call_handle_stop(server.module, response, server.state) do
      {:continue, prompt, new_state} ->
        server = %{server | state: new_state}

        cond do
          max_steps_reached?(server) ->
            commit_and_done(response, server)

          server.next_prompt != nil ->
            content = server.next_prompt
            server = %{server | next_prompt: nil}
            continue_turn(content, response, server)

          true ->
            continue_turn(prompt, response, server)
        end

      {:stop, new_state} ->
        server = %{server | state: new_state}

        cond do
          server.next_prompt != nil and not max_steps_reached?(server) ->
            content = server.next_prompt
            server = %{server | next_prompt: nil}
            continue_turn(content, response, server)

          true ->
            commit_and_done(response, server)
        end
    end
  end

  defp continue_turn(prompt, response, server) do
    notify(server, :turn, response)
    user_message = Message.new(role: :user, content: prompt)
    server = %{server | pending_messages: server.pending_messages ++ [user_message]}
    spawn_step(server)
  end

  defp commit_and_done(response, server) do
    context = Context.push(server.state.context, server.pending_messages)

    server = %{
      server
      | state: %{server.state | context: context, status: :idle, step: 0},
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        pending_messages: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        tool_map: nil,
        approved_uses: [],
        remaining_uses: [],
        paused_use: nil
    }

    notify(server, :done, response)
    server
  end

  # -- Cancel --

  defp do_cancel(server) do
    kill_task(server.step_task)
    kill_task(server.executor_task)

    server
    |> reset_round()
    |> tap(&notify(&1, :cancelled, nil))
  end

  defp kill_task(nil), do: :ok
  defp kill_task({pid, _ref}), do: Process.exit(pid, :kill)

  # -- Helpers --

  defp reset_round(server) do
    %{
      server
      | state: %{server.state | status: :idle, step: 0},
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        pending_messages: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        tool_map: nil,
        approved_uses: [],
        remaining_uses: [],
        paused_use: nil
    }
  end

  defp max_steps_reached?(server) do
    max = Keyword.get(server.prompt_opts, :max_steps, :infinity)
    max != :infinity and server.state.step >= max
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
