defmodule Omni.Agent.Server do
  @moduledoc false

  # Lifecycle: round > turn > step
  #
  #   prompt/3 ──► ROUND START
  #   │
  #   ├─ Turn 1
  #   │   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete
  #   │   │   └─ tool_use? ──► handle_tool_decision_phase ──► spawn_executor
  #   │   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete
  #   │   │   └─ tool_use? ──► ...repeat...
  #   │   └─ evaluate_head ──► assistant (no tools) ──► finalize_turn ──► handle_stop
  #   │       └─ {:continue, prompt} ──► :turn event
  #   │
  #   ├─ Turn 2 (same structure)
  #   │   └─ ...
  #   │
  #   └─ Final turn: handle_stop returns {:stop, _}
  #       └─ complete_round ──► :done event ──► ROUND END

  use GenServer

  alias Omni.{Context, Message, MessageTree, Model, Response, Tool, Usage}
  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}

  defstruct [
    # Public state (passed to callbacks)
    :state,

    # Configuration (set at init, stable across rounds)
    :module,
    :listener,
    :tool_timeout,

    # Round lifecycle (set when a prompt starts, cleared by reset_round)
    # round_origin_id: tree head ID before the round started (for rollback)
    # round_message_ids: list of node IDs pushed during this round
    # pending_usage: accumulated usage for the current round across all steps
    # prompt_opts: merged opts for the current round (state.opts + call-site opts)
    # next_prompt: staged {content, opts} tuple for the next round, set when
    #   prompt/3 is called while running/paused
    round_origin_id: nil,
    round_message_ids: [],
    pending_usage: %Usage{},
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

  @settable_fields [:model, :system, :tools, :tree, :opts, :meta]

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
         {:ok, private} <- call_init(module, opts) do
      agent_state = %State{
        model: model,
        system: opts[:system],
        tools: opts[:tools] || [],
        tree: opts[:tree] || %MessageTree{},
        opts: Keyword.get(opts, :opts, []),
        meta: opts[:meta] || %{},
        private: private
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
    server = start_round(content, opts, server)
    {:reply, :ok, server}
  end

  def handle_call(
        {:prompt, content, opts},
        {from_pid, _},
        %__MODULE__{state: %{status: :error}} = server
      ) do
    server = if server.listener == nil, do: %{server | listener: from_pid}, else: server

    # Rollback to round_origin_id, then start fresh
    server = rollback_tree(server)
    server = reset_round(server)
    server = start_round(content, opts, server)
    {:reply, :ok, server}
  end

  def handle_call(
        {:prompt, content, opts},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:running, :paused] do
    {:reply, :ok, %{server | next_prompt: {content, opts}}}
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

  def handle_call(:cancel, _from, %__MODULE__{state: %{status: status}} = server)
      when status in [:running, :paused, :error] do
    server = do_cancel(server)
    {:reply, :ok, server}
  end

  def handle_call(:cancel, _from, %__MODULE__{state: %{status: :idle}} = server) do
    {:reply, {:error, :idle}, server}
  end

  def handle_call(:retry, _from, %__MODULE__{state: %{status: :error}} = server) do
    server = %{server | state: %{server.state | status: :running}}
    server = evaluate_head(server)
    {:reply, :ok, server}
  end

  def handle_call(:retry, _from, server) do
    {:reply, {:error, :not_error}, server}
  end

  def handle_call({:listen, pid}, _from, %__MODULE__{state: %{status: status}} = server)
      when status in [:idle, :error] do
    {:reply, :ok, %{server | listener: pid}}
  end

  def handle_call(
        {:navigate, node_id},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:idle, :error] do
    # If navigating from :error, reset the failed round first
    server =
      if status == :error do
        rollback_tree(server) |> reset_round()
      else
        server
      end

    case MessageTree.navigate(server.state.tree, node_id) do
      {:ok, tree} ->
        server = %{server | state: %{server.state | tree: tree}}
        head_id = MessageTree.head(tree)
        node = MessageTree.get_node(tree, head_id)

        if should_start_round?(node, server.state.tools) do
          origin_id = navigate_origin_id(node)
          prompt_opts = Keyword.merge(server.state.opts, [])

          server = %{
            server
            | state: %{server.state | tree: tree, status: :running, step: 0},
              round_origin_id: origin_id,
              round_message_ids: [],
              prompt_opts: prompt_opts
          }

          server = evaluate_head(server)
          {:reply, :ok, server}
        else
          {:reply, :ok, server}
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, server}
    end
  end

  # -- set_state/2 --

  def handle_call(
        {:set_state, opts},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:idle, :error] do
    case apply_set_state(server.state, opts) do
      {:ok, new_state} -> {:reply, :ok, %{server | state: new_state}}
      {:error, _} = error -> {:reply, error, server}
    end
  end

  # -- set_state/3 --

  def handle_call(
        {:set_state, field, value_or_fun},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:idle, :error] and field in @settable_fields do
    new_value =
      if is_function(value_or_fun, 1),
        do: value_or_fun.(Map.get(server.state, field)),
        else: value_or_fun

    case maybe_resolve_field(field, new_value) do
      {:ok, resolved} ->
        {:reply, :ok, %{server | state: Map.put(server.state, field, resolved)}}

      {:error, _} = error ->
        {:reply, error, server}
    end
  end

  def handle_call(
        {:set_state, field, _value_or_fun},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:idle, :error] do
    {:reply, {:error, {:invalid_field, field}}, server}
  end

  # Catch-all for mutating ops while running or paused
  def handle_call({:listen, _}, _from, server), do: {:reply, {:error, :running}, server}
  def handle_call({:navigate, _}, _from, server), do: {:reply, {:error, :not_idle}, server}
  def handle_call({:set_state, _}, _from, server), do: {:reply, {:error, :running}, server}
  def handle_call({:set_state, _, _}, _from, server), do: {:reply, {:error, :running}, server}

  def handle_call(:get_state, _from, server), do: {:reply, server.state, server}

  def handle_call({:get_state, key}, _from, server),
    do: {:reply, Map.get(server.state, key), server}

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
        notify(server, :retry, reason)
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = %{server | state: %{new_state | status: :error}}
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
        notify(server, :retry, error)
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = %{server | state: %{new_state | status: :error}}
        notify(server, :error, error)
        {:noreply, server}
    end
  end

  # -- Info (executor messages) --

  def handle_info({ref, {:tools_executed, results}}, %{executor_task: {_, ref}} = server) do
    server = handle_tools_executed(results, server)
    {:noreply, server}
  end

  def handle_info({:EXIT, pid, reason}, %{executor_task: {pid, _}} = server)
      when reason not in [:normal, :killed] do
    error = {:executor_crashed, reason}
    server = %{server | executor_task: nil, state: %{server.state | status: :error}}
    notify(server, :error, error)
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

  # -- Round start --

  defp start_round(content, opts, server) do
    user_message = Message.new(role: :user, content: content)
    prompt_opts = Keyword.merge(server.state.opts, opts)
    origin_id = MessageTree.head(server.state.tree)

    {id, tree} = MessageTree.push(server.state.tree, user_message)

    %{
      server
      | state: %{server.state | status: :running, step: 0, tree: tree},
        round_origin_id: origin_id,
        round_message_ids: [id],
        prompt_opts: prompt_opts
    }
    |> evaluate_head()
  end

  # -- evaluate_head: unified state machine --

  defp evaluate_head(server) do
    if max_steps_reached?(server) do
      finalize_turn(server.last_response, server)
    else
      head_id = MessageTree.head(server.state.tree)
      node = MessageTree.get_node(server.state.tree, head_id)

      cond do
        node.message.role == :user ->
          spawn_step(server)

        has_executable_tools?(node.message, server.state.tools) ->
          tool_uses = extract_tool_uses(node.message.content)
          handle_tool_decision_phase(tool_uses, server)

        true ->
          finalize_turn(server.last_response, server)
      end
    end
  end

  defp has_executable_tools?(message, tools) do
    tool_uses = extract_tool_uses(message.content)
    tool_map = build_tool_map(tools)

    tool_uses != [] and
      not Enum.any?(tool_uses, fn tool_use ->
        match?(%Tool{handler: nil}, Map.get(tool_map, tool_use.name))
      end)
  end

  # -- Step execution --

  defp spawn_step(server) do
    full_context = build_context(server)

    opts = Keyword.merge(server.prompt_opts, max_steps: 1)
    ref = make_ref()

    {:ok, pid} = Omni.Agent.Step.start_link(self(), ref, server.state.model, full_context, opts)

    step = server.state.step + 1
    %{server | step_task: {pid, ref}, state: %{server.state | step: step}}
  end

  defp build_context(server) do
    messages = MessageTree.messages(server.state.tree)

    %Context{
      system: server.state.system,
      messages: messages,
      tools: server.state.tools
    }
  end

  # -- Step completion --

  defp handle_step_complete(response, server) do
    pending_usage = Usage.add(server.pending_usage, response.usage)

    # Push assistant message to tree with stop_reason
    {id, tree} =
      MessageTree.push(server.state.tree, response.message, response.stop_reason)

    server = %{
      server
      | state: %{server.state | tree: tree},
        round_message_ids: server.round_message_ids ++ [id],
        step_task: nil,
        last_response: response,
        pending_usage: pending_usage
    }

    evaluate_head(server)
  end

  # -- Tool decision phase --

  defp handle_tool_decision_phase(tool_uses, server) do
    tool_map = build_tool_map(server.state.tools)

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

            notify(srv, :tool_result, final_result)

            {final_result, srv}
        end
      end)

    # Build user message with all tool results, push to tree
    user_message = Message.new(role: :user, content: final_results)
    {id, tree} = MessageTree.push(server.state.tree, user_message)

    server = %{
      server
      | state: %{server.state | tree: tree},
        round_message_ids: server.round_message_ids ++ [id]
    }

    evaluate_head(server)
  end

  # -- Finalize turn --

  defp finalize_turn(response, server) do
    case call_handle_stop(server.module, response, server.state) do
      {:continue, prompt, new_state} ->
        server = %{server | state: new_state}

        cond do
          max_steps_reached?(server) ->
            complete_round(response, server)

          server.next_prompt != nil ->
            {content, opts} = server.next_prompt
            prompt_opts = Keyword.merge(server.state.opts, opts)
            server = %{server | next_prompt: nil, prompt_opts: prompt_opts}
            continue_turn(content, server)

          true ->
            continue_turn(prompt, server)
        end

      {:stop, new_state} ->
        server = %{server | state: new_state}

        cond do
          server.next_prompt != nil and not max_steps_reached?(server) ->
            {content, opts} = server.next_prompt
            prompt_opts = Keyword.merge(server.state.opts, opts)
            server = %{server | next_prompt: nil, prompt_opts: prompt_opts}
            continue_turn(content, server)

          true ->
            complete_round(response, server)
        end
    end
  end

  defp continue_turn(prompt, server) do
    response = build_round_response(server)
    notify(server, :turn, response)

    # Push continuation user message to tree
    user_message = Message.new(role: :user, content: prompt)
    {id, tree} = MessageTree.push(server.state.tree, user_message)

    server = %{
      server
      | state: %{server.state | tree: tree},
        round_message_ids: server.round_message_ids ++ [id]
    }

    evaluate_head(server)
  end

  defp complete_round(_response, server) do
    new_usage = Usage.add(server.state.usage, server.pending_usage)
    server = %{server | state: %{server.state | usage: new_usage}}

    response = build_round_response(server)
    server = reset_round(server)
    notify(server, :done, response)
    server
  end

  # -- Cancel --

  defp do_cancel(server) do
    kill_task(server.step_task)
    kill_task(server.executor_task)

    response = build_cancel_response(server)
    server = rollback_tree(server)
    server = reset_round(server)
    notify(server, :cancelled, response)
    server
  end

  defp kill_task(nil), do: :ok
  defp kill_task({pid, _ref}), do: Process.exit(pid, :kill)

  # -- Navigate helpers --

  defp should_start_round?(node, tools) do
    node.message.role == :user or has_executable_tools?(node.message, tools)
  end

  defp navigate_origin_id(node) do
    if node.message.role == :user do
      node.parent_id
    else
      node.id
    end
  end

  # -- Tree rollback --

  defp rollback_tree(server) do
    tree =
      case server.round_origin_id do
        nil ->
          MessageTree.clear(server.state.tree)

        origin_id ->
          {:ok, tree} = MessageTree.navigate(server.state.tree, origin_id)
          tree
      end

    %{server | state: %{server.state | tree: tree}}
  end

  # -- Response builders --

  defp build_round_response(server) do
    messages = round_messages(server)
    last_assistant = find_last_assistant(messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: messages,
      node_ids: server.round_message_ids,
      stop_reason: if(server.last_response, do: server.last_response.stop_reason, else: :stop),
      usage: server.pending_usage
    }
  end

  defp build_cancel_response(server) do
    messages = round_messages(server)
    last_assistant = find_last_assistant(messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: messages,
      node_ids: server.round_message_ids,
      stop_reason: :cancelled,
      usage: server.pending_usage
    }
  end

  defp round_messages(server) do
    Enum.map(server.round_message_ids, &server.state.tree.nodes[&1].message)
  end

  defp find_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end

  # -- set_state --

  defp apply_set_state(state, opts) do
    with :ok <- validate_set_state_keys(opts),
         {:ok, state} <- maybe_resolve_model(state, opts) do
      state =
        Enum.reduce(opts, state, fn
          {:model, _}, acc -> acc
          {key, value}, acc -> Map.put(acc, key, value)
        end)

      {:ok, state}
    end
  end

  defp validate_set_state_keys(opts) do
    case Enum.find(opts, fn {key, _} -> key not in @settable_fields end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_key, key}}
    end
  end

  defp maybe_resolve_model(state, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model_ref} ->
        case resolve_model(model_ref) do
          {:ok, model} -> {:ok, %{state | model: model}}
          {:error, _} -> {:error, {:model_not_found, model_ref}}
        end

      :error ->
        {:ok, state}
    end
  end

  defp maybe_resolve_field(:model, value) do
    case resolve_model(value) do
      {:ok, model} -> {:ok, model}
      {:error, _} -> {:error, {:model_not_found, value}}
    end
  end

  defp maybe_resolve_field(_field, value), do: {:ok, value}

  # -- Helpers --

  defp reset_round(server) do
    %{
      server
      | state: %{server.state | status: :idle, step: 0},
        pending_usage: %Usage{},
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        round_origin_id: nil,
        round_message_ids: [],
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
