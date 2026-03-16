defmodule Omni.Agent do
  @moduledoc """
  A supervised process that manages multi-turn LLM conversations.

  An agent holds a model, a conversation tree (system prompt, messages,
  tools), and user-defined state. The outside world sends prompts in; the
  agent streams events back. Between turns, lifecycle callbacks control
  whether the agent continues, stops, or pauses for human approval.

  Use an agent instead of the stateless `generate_text`/`stream_text` API when
  you need the process to own the conversation — managing context, executing
  tools with approval gates, and looping autonomously across multiple turns.

  ## Quick start

  Start an agent without a callback module for simple conversations:

      {:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-sonnet-4-5-20250514"})
      :ok = Omni.Agent.prompt(agent, "Hello!")

      # Events arrive as process messages
      receive do
        {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
        {:agent, ^agent, :done, response} -> IO.puts("\\nDone!")
      end

  The first `prompt/3` call automatically sets the caller as the event
  listener. Call `listen/2` to set a different process.

  ## Custom agents

  Define a module with `use Omni.Agent` to customize behaviour through
  lifecycle callbacks. All callbacks are optional with sensible defaults:

      defmodule MyAgent do
        use Omni.Agent

        @impl Omni.Agent
        def init(opts) do
          {:ok, %{user: opts[:user]}}
        end

        @impl Omni.Agent
        def handle_stop(%{stop_reason: :length}, state) do
          {:continue, "Continue where you left off.", state}
        end

        def handle_stop(_response, state) do
          {:stop, state}
        end
      end

      {:ok, agent} = MyAgent.start_link(
        model: {:anthropic, "claude-sonnet-4-5-20250514"},
        system: "You are a helpful assistant.",
        user: :current_user
      )

  Override `start_link/1` to bake in defaults — standard GenServer pattern:

      defmodule MyAgent do
        use Omni.Agent

        def start_link(opts \\\\ []) do
          defaults = [
            model: {:anthropic, "claude-sonnet-4-5-20250514"},
            system: "You are a research assistant.",
            tools: [SearchTool.new(), FetchTool.new()]
          ]
          super(Keyword.merge(defaults, opts))
        end
      end

  ## Start options

  Options for `start_link/1` and `start_link/2`:

    * `:model` (required) — `{provider_id, model_id}` tuple or `%Model{}`
    * `:system` — system prompt string
    * `:tools` — list of `%Tool{}` structs
    * `:meta` — initial metadata map (serializable user data, persisted by storage)
    * `:listener` — pid to receive events (defaults to first `prompt/3` caller)
    * `:tool_timeout` — per-tool execution timeout in ms (default `5_000`)
    * `:opts` — inference options passed to `stream_text` each step
      (`:temperature`, `:max_tokens`, `:max_steps`, etc.)
    * `:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug` —
      standard GenServer options

  ## Events

  The listener receives `{:agent, pid, type, data}` messages. There are two
  categories:

  **Streaming events** — forwarded from each LLM response as it arrives:

      {:agent, pid, :text_start,     %{index: 0}}
      {:agent, pid, :text_delta,     %{index: 0, delta: "Hello"}}
      {:agent, pid, :text_end,       %{index: 0, content: %Text{}}}
      {:agent, pid, :thinking_start, %{index: 0}}
      {:agent, pid, :thinking_delta, %{index: 0, delta: "..."}}
      {:agent, pid, :thinking_end,   %{index: 0, content: %Thinking{}}}
      {:agent, pid, :tool_use_start, %{index: 1, id: "call_1", name: "search"}}
      {:agent, pid, :tool_use_delta, %{index: 1, delta: "{\\"q\\":"}}
      {:agent, pid, :tool_use_end,   %{index: 1, content: %ToolUse{}}}

  **Agent-level events** — emitted by the agent at lifecycle boundaries:

      {:agent, pid, :tool_result, %ToolResult{}}  # tool executed, result available
      {:agent, pid, :turn,        %Response{}}    # intermediate turn, agent continuing
      {:agent, pid, :done,        %Response{}}    # prompt round complete
      {:agent, pid, :pause,       %ToolUse{}}     # waiting for tool approval
      {:agent, pid, :retry,       reason}         # non-terminal error, agent retrying
      {:agent, pid, :error,       reason}         # terminal error, round is over
      {:agent, pid, :cancelled,   nil}            # cancel was invoked

  `:turn` fires after each intermediate turn (where `handle_stop` returned
  `{:continue, ...}`). `:done` fires after the final turn. A simple chatbot
  (one turn per prompt) never sees `:turn`, only `:done`.

  ## Tools and the agent loop

  The agent manages its own tool execution loop, separate from the stateless
  loop used by `generate_text`/`stream_text`. This enables per-tool approval
  gates and pause/resume — capabilities that the stateless loop cannot support.

  When the model responds with tool use blocks, the agent processes them in
  two phases:

  1. **Decision phase** — `handle_tool_call/2` is called sequentially for each
     tool use. Return `{:execute, state}` to approve, `{:reject, reason, state}`
     to send an error result, or `{:pause, state}` to wait for external approval
     via `resume/2`.

  2. **Execution phase** — approved tools run in parallel. Results are passed to
     `handle_tool_result/2`, then sent back to the model as a user message.
     The agent spawns the next LLM request automatically.

  Schema-only tools (no handler) skip both phases — the response goes straight
  to `handle_stop` with `stop_reason: :tool_use`. See the "Autonomous agents"
  section below.

  ## Pause and resume

  When `handle_tool_call/2` returns `{:pause, state}`, the agent pauses and
  sends `{:agent, pid, :pause, %ToolUse{}}` to the listener. The caller
  inspects the tool call and resumes:

      Agent.resume(agent, :approve)            # approve and continue
      Agent.resume(agent, {:reject, "Denied"}) # reject with error result

  After resuming, the agent continues processing remaining tool decisions.
  Pause exists solely for tool call approval — no other callback can pause.

  ## Prompt queuing

  Calling `prompt/3` while the agent is running or paused stages the content
  for the next turn boundary. When the current turn completes:

    * `handle_stop/2` fires as normal (for bookkeeping, state updates)
    * The staged prompt overrides `handle_stop`'s decision — the agent
      continues with the staged content regardless of whether the callback
      returned `{:stop, state}` or `{:continue, ...}`

  This enables steering an autonomous agent mid-run:

      :ok = Agent.prompt(agent, "Stop what you're doing, focus on X instead")

  Calling `prompt/3` again replaces the staged prompt (last-one-wins).

  ## Autonomous agents

  The difference between a chatbot (one turn per prompt) and an autonomous
  agent (works until done) is entirely in the callbacks. A schema-only tool
  serves as the completion signal:

      task_complete = Omni.tool(
        name: "task_complete",
        description: "Call when the task is fully complete.",
        input_schema: Omni.Schema.object(
          %{result: Omni.Schema.string(description: "Summary of what was accomplished")},
          required: [:result]
        )
      )

  The agent loops until the model calls it:

      defmodule ResearchAgent do
        use Omni.Agent

        def start_link(opts \\\\ []) do
          defaults = [
            model: {:anthropic, "claude-sonnet-4-5-20250514"},
            system: "You are a research assistant. Use your tools to research, " <>
                    "then call task_complete with your findings.",
            tools: [SearchTool.new(), FetchTool.new(), task_complete],
            opts: [max_steps: 30]
          ]
          super(Keyword.merge(defaults, opts))
        end

        @impl Omni.Agent
        def handle_stop(%{stop_reason: :tool_use} = response, state) do
          # Model called schema-only tool — extract result and stop
          {:stop, state}
        end

        def handle_stop(%{stop_reason: :length}, state) do
          {:continue, "Continue where you left off.", state}
        end

        def handle_stop(%{stop_reason: :stop}, state) do
          # Model responded with text instead of calling task_complete
          {:continue, "Continue working. Call task_complete when finished.", state}
        end

        def handle_stop(_response, state), do: {:stop, state}
      end

  ## Steps, turns, and max_steps

  The agent loop has two levels:

    * **Step** — a single LLM request-response cycle. If the model calls tools,
      the agent handles them and makes another request. Each request is one step.
    * **Turn** — a complete unit of work ending when the model responds without
      calling executable tools. A turn may contain multiple steps. `handle_stop`
      fires at each turn boundary.

  A prompt round may span multiple turns (when `handle_stop` returns
  `{:continue, ...}`), and each turn may span multiple steps:

      prompt round
        turn 1: step → tool_use → step → tool_use → step → :stop → handle_stop
          → {:continue, "keep going"}
        turn 2: step → :stop → handle_stop
          → {:stop, state} → :done

  `:max_steps` (default `:infinity`) caps the total number of LLM requests
  across the entire prompt round. Set it in `:opts` at startup or override
  per-prompt via `prompt/3`:

      Agent.prompt(agent, "Do exhaustive research", max_steps: 50)

  The step counter (`state.step`) is visible in all callbacks.

  ## LiveView integration

  Agent events map naturally to `handle_info/2`:

      def handle_event("submit", %{"prompt" => text}, socket) do
        :ok = Agent.prompt(socket.assigns.agent, text)
        {:noreply, socket}
      end

      def handle_info({:agent, _pid, :text_delta, %{delta: text}}, socket) do
        {:noreply, stream_insert(socket, :chunks, %{text: text})}
      end

      def handle_info({:agent, _pid, :done, _response}, socket) do
        {:noreply, assign(socket, :status, :complete)}
      end

      def handle_info({:agent, _pid, :error, reason}, socket) do
        {:noreply, put_flash(socket, :error, "Agent error: \#{inspect(reason)}")}
      end
  """

  alias Omni.{MessageTree, Usage}
  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}
  alias Omni.Response

  @doc """
  Called when the agent starts.

  Receives the full opts passed to `start_link` (including framework keys like
  `:model` and `:system` — ignore what you don't need). Return `{:ok, private}`
  to start with initial private state, or `{:error, reason}` to refuse startup.

  Private state holds runtime data (PIDs, refs, closures) that persists across
  callbacks and prompt rounds but is not serialized by storage. Access via
  `state.private` in other callbacks.

  Default: `{:ok, %{}}`.
  """
  @callback init(opts :: keyword()) :: {:ok, private :: map()} | {:error, term()}

  @doc """
  Called at each turn boundary to decide whether to continue or stop.

  Fires after the model responds without calling executable tools (or with
  only schema-only tools). The `response` contains the model's message and
  metadata — check `response.stop_reason` for why the turn ended:

    * `:stop` — the model finished naturally
    * `:tool_use` — the model called a schema-only tool (completion signal)
    * `:length` — output was truncated (hit max output tokens)
    * `:refusal` — the model declined due to content or safety policy

  Return `{:stop, state}` to end the prompt round (listener receives `:done`),
  or `{:continue, content, state}` to append a user message and start another
  turn. The `content` argument accepts a string or a list of content blocks
  (including `ToolResult` blocks for manual tool execution).

  If a staged prompt exists (from `prompt/3` while running), it overrides this
  callback's decision. See the "Prompt queuing" section in the moduledoc.

  Default: `{:stop, state}`.
  """
  @callback handle_stop(response :: Response.t(), state :: State.t()) ::
              {:stop, State.t()} | {:continue, term(), State.t()}

  @doc """
  Called for each tool use block during the decision phase.

  When the model responds with tool use blocks, this callback is invoked
  sequentially for each one before any tools execute. Return values:

    * `{:execute, state}` — approve the tool for execution
    * `{:reject, reason, state}` — send an error result to the model
    * `{:pause, state}` — pause the agent and send `{:agent, pid, :pause,
      tool_use}` to the listener; resume later with `resume/2`

  After all decisions are collected, approved tools execute in parallel.
  Rejected tools receive error results without executing.

  Default: `{:execute, state}`.
  """
  @callback handle_tool_call(tool_use :: ToolUse.t(), state :: State.t()) ::
              {:execute, State.t()} | {:reject, term(), State.t()} | {:pause, State.t()}

  @doc """
  Called after each tool executes, before results are sent to the model.

  Invoked sequentially for each result after all approved tools have finished
  executing in parallel. Return `{:ok, result, state}` to pass the result
  through, or modify `result` before returning to alter what the model sees.

  Default: `{:ok, result, state}`.
  """
  @callback handle_tool_result(result :: ToolResult.t(), state :: State.t()) ::
              {:ok, ToolResult.t(), State.t()}

  @doc """
  Called when an LLM request fails entirely.

  This fires when `stream_text` returns `{:error, reason}` — a network
  failure, authentication error, or other request-level problem. This is
  distinct from `handle_stop` with an error stop reason, which means the
  request succeeded but the API returned an error in the response body.

  Return `{:stop, state}` to surface the error to the listener, or
  `{:retry, state}` to retry the same step immediately.

  Default: `{:stop, state}`.
  """
  @callback handle_error(error :: term(), state :: State.t()) ::
              {:stop, State.t()} | {:retry, State.t()}

  @doc """
  Called when the agent process terminates.

  Use for cleaning up resources acquired in `init/1`. Receives the shutdown
  reason and the current state. Standard GenServer termination semantics apply.

  Default: no-op.
  """
  @callback terminate(reason :: term(), state :: State.t()) :: term()

  @genserver_keys [:name, :timeout, :hibernate_after, :spawn_opt, :debug]

  defmacro __using__(_opts) do
    quote do
      @behaviour Omni.Agent

      @impl Omni.Agent
      def init(_opts), do: {:ok, %{}}

      @impl Omni.Agent
      def handle_stop(_response, state), do: {:stop, state}

      @impl Omni.Agent
      def handle_tool_call(_tool_use, state), do: {:execute, state}

      @impl Omni.Agent
      def handle_tool_result(result, state), do: {:ok, result, state}

      @impl Omni.Agent
      def handle_error(_error, state), do: {:stop, state}

      @impl Omni.Agent
      def terminate(_reason, _state), do: :ok

      @doc "Starts and links an agent process with this callback module."
      def start_link(opts) do
        Omni.Agent.start_link(__MODULE__, opts)
      end

      defoverridable init: 1,
                     handle_stop: 2,
                     handle_tool_call: 2,
                     handle_tool_result: 2,
                     handle_error: 2,
                     terminate: 2,
                     start_link: 1
    end
  end

  @doc """
  Starts and links an agent process without a callback module.

  All default callbacks apply (single turn per prompt, all tools auto-executed,
  errors stop the agent). See "Start options" in the moduledoc for accepted
  keys.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    start_link(nil, opts)
  end

  @doc """
  Starts and links an agent process with the given callback module.

  The module must `use Omni.Agent`. See "Start options" in the moduledoc for
  accepted keys.
  """
  @spec start_link(module() | nil, keyword()) :: GenServer.on_start()
  def start_link(module, opts) do
    {gs_opts, opts} = Keyword.split(opts, @genserver_keys)
    Omni.Agent.Server.start_link({module, opts}, gs_opts)
  end

  @doc """
  Sends a prompt to the agent.

  `content` accepts a string (wrapped in a `Text` block) or a list of content
  blocks (for attachments or `ToolResult` blocks for manual tool execution).
  Options are merged on top of the agent's default `:opts` for this round only.

  Behaviour depends on agent status:

    * **Idle** — starts a new prompt round immediately.
    * **Running or paused** — stages the content for the next turn boundary,
      overriding `handle_stop`'s decision. See "Prompt queuing" in the moduledoc.
  """
  @spec prompt(GenServer.server(), term(), keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc """
  Resumes a paused agent with a tool decision.

  Only valid when the agent is `:paused` (from `handle_tool_call/2` returning
  `{:pause, state}`). The agent continues processing remaining tool decisions
  after resuming.

    * `:approve` — approve the pending tool for execution
    * `{:reject, reason}` — reject with an error result sent to the model

  Returns `{:error, :not_paused}` if the agent is not paused.
  """
  @spec resume(GenServer.server(), :approve | {:reject, term()}) :: :ok | {:error, :not_paused}
  def resume(agent, decision) do
    GenServer.call(agent, {:resume, decision})
  end

  @doc """
  Cancels the current prompt round.

  Kills any running tasks, discards all in-progress messages, and leaves the
  conversation tree unchanged. The listener receives
  `{:agent, pid, :cancelled, nil}`.

  Returns `{:error, :idle}` if the agent is already idle.
  """
  @spec cancel(GenServer.server()) :: :ok | {:error, :idle}
  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc """
  Adds tools to the agent.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec add_tools(GenServer.server(), [Omni.Tool.t()]) :: :ok | {:error, :running}
  def add_tools(agent, tools) do
    GenServer.call(agent, {:add_tools, tools})
  end

  @doc """
  Removes tools by name from the agent.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec remove_tools(GenServer.server(), [String.t()]) :: :ok | {:error, :running}
  def remove_tools(agent, tool_names) do
    GenServer.call(agent, {:remove_tools, tool_names})
  end

  @doc """
  Starts a new session, discarding the conversation tree.

  Generates a new session ID and replaces the tree with a fresh
  `%MessageTree{}`. Preserves system prompt, tools, model, opts, meta, and
  private. Returns the new session ID.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec clear(GenServer.server()) :: {:ok, String.t()} | {:error, :running}
  def clear(agent) do
    GenServer.call(agent, :clear)
  end

  @doc """
  Sets the listener process for agent events.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec listen(GenServer.server(), pid()) :: :ok | {:error, :running}
  def listen(agent, pid) do
    GenServer.call(agent, {:listen, pid})
  end

  @doc """
  Returns the agent's `%State{}` struct or a single field from it.

  With no key, returns the full `%State{}`. With a key, returns the value of
  that field (or `nil` for unknown keys).

      Agent.get_state(agent)            #=> %State{model: ..., tree: ..., ...}
      Agent.get_state(agent, :status)   #=> :idle
      Agent.get_state(agent, :tree)     #=> %MessageTree{}
      Agent.get_state(agent, :private)  #=> %{}
  """
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(agent), do: GenServer.call(agent, :get_state)

  @spec get_state(GenServer.server(), atom()) :: term()
  def get_state(agent, key) when is_atom(key), do: GenServer.call(agent, {:get_state, key})

  @doc """
  Returns cumulative token usage across all rounds in the conversation tree.

  Computed via `MessageTree.usage/1`, which sums all rounds (including
  inactive branches). Returns `%Usage{}` for a fresh agent with no rounds.
  """
  @spec usage(GenServer.server()) :: Usage.t()
  def usage(agent) do
    GenServer.call(agent, :usage)
  end

  @doc """
  Updates agent configuration. Idle only. Atomic.

  Accepts the following keys:

    * `:model` — replace the model. Resolved via `Omni.get_model/2`.
      Fails with `{:error, {:model_not_found, ref}}` if not found
    * `:system` — replace the system prompt (string or `nil`)
    * `:opts` — merge onto existing inference opts (`Keyword.merge/2`)
    * `:meta` — merge onto existing meta (`Map.merge/2`)

  Unrecognized keys return `{:error, {:invalid_key, key}}`. Use `add_tools/2`
  and `remove_tools/2` to manage tools.

  Returns `{:error, :running}` if the agent is running or paused.
  """
  @spec configure(GenServer.server(), keyword()) :: :ok | {:error, :running} | {:error, term()}
  def configure(agent, opts) when is_list(opts) do
    GenServer.call(agent, {:configure, opts})
  end

  @doc """
  Transforms a configuration field using a function. Idle only.

  Only `:opts` and `:meta` are supported — other fields return
  `{:error, {:invalid_field, field}}`. The function receives the current
  value and must return the new value.

      Agent.configure(agent, :opts, fn opts -> Keyword.drop(opts, [:temperature]) end)
      Agent.configure(agent, :meta, fn meta -> Map.delete(meta, :title) end)

  Returns `{:error, :running}` if the agent is running or paused.
  """
  @spec configure(GenServer.server(), atom(), (term() -> term())) ::
          :ok | {:error, :running} | {:error, term()}
  def configure(agent, field, fun) when is_atom(field) and is_function(fun, 1) do
    GenServer.call(agent, {:configure, field, fun})
  end

  @doc """
  Sets the active conversation path to the given round.

  Delegates to `MessageTree.navigate/2`. The next `prompt/3` call will
  branch from this point. Returns the updated tree for immediate UI rendering.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec navigate(GenServer.server(), MessageTree.round_id()) ::
          {:ok, MessageTree.t()} | {:error, :running} | {:error, :not_found}
  def navigate(agent, round_id) do
    GenServer.call(agent, {:navigate, round_id})
  end
end
