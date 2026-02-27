defmodule Omni.Agent.Server do
  @moduledoc false

  use GenServer

  alias Omni.{Context, Message, Model, Response, Usage}
  alias Omni.Agent.State

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
        listener: opts[:listener]
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

  def handle_call({:prompt, _content, _opts}, _from, %{status: :running} = state) do
    {:reply, {:error, :running}, state}
  end

  def handle_call(:cancel, _from, %{status: :running} = state) do
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

  def handle_call(:clear, _from, %{status: :running} = state) do
    {:reply, {:error, :running}, state}
  end

  def handle_call({:listen, pid}, _from, %{status: :idle} = state) do
    {:reply, :ok, %{state | listener: pid}}
  end

  def handle_call({:listen, _pid}, _from, %{status: :running} = state) do
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
    state = reset_round(state)
    notify(state, :error, reason)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{step_task: {pid, _}} = state)
      when reason not in [:normal, :killed] do
    state = reset_round(state)
    notify(state, :error, {:step_crashed, reason})
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

    state = %{state | pending_messages: pending, usage: usage}

    case call_handle_stop(state.module, response, state) do
      {:stop, new_state} ->
        context = %{state.context | messages: state.context.messages ++ pending}

        %{
          new_state
          | context: context,
            status: :idle,
            step: 0,
            step_task: nil,
            pending_messages: [],
            prompt_opts: []
        }
        |> tap(&notify(&1, :done, response))
    end
  end

  # -- Cancel --

  defp do_cancel(state) do
    {pid, _ref} = state.step_task
    Process.exit(pid, :kill)

    state
    |> reset_round()
    |> tap(&notify(&1, :cancelled, nil))
  end

  # -- Helpers --

  defp reset_round(state) do
    %{
      state
      | status: :idle,
        step: 0,
        step_task: nil,
        pending_messages: [],
        prompt_opts: []
    }
  end

  defp notify(%{listener: nil}, _type, _data), do: :ok
  defp notify(%{listener: pid}, type, data), do: send(pid, {:agent, self(), type, data})

  # -- Callback dispatch --

  defp call_init(nil, _opts), do: {:ok, %{}}
  defp call_init(module, opts), do: module.init(opts)

  defp call_handle_stop(nil, _response, state), do: {:stop, state}
  defp call_handle_stop(module, response, state), do: module.handle_stop(response, state)

  defp call_terminate(nil, _reason, _state), do: :ok
  defp call_terminate(module, reason, state), do: module.terminate(reason, state)
end
