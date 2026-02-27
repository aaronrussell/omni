defmodule Omni.Agent do
  @moduledoc """
  A stateful agent that manages multi-turn conversations with an LLM.

  Agents wrap `Omni.stream_text/3` in a GenServer, maintaining conversation
  context, accumulating usage, and streaming events to a listener process.

  ## Using as a behaviour

  Define a module with `use Omni.Agent` to customize agent behaviour:

      defmodule MyAgent do
        use Omni.Agent

        @impl Omni.Agent
        def init(opts) do
          {:ok, %{name: opts[:name] || "assistant"}}
        end

        @impl Omni.Agent
        def handle_stop(response, state) do
          if should_continue?(response) do
            {:continue, "Keep going.", state}
          else
            {:stop, state}
          end
        end
      end

      {:ok, agent} = MyAgent.start_link(model: {:anthropic, "claude-haiku-4-5"})

  ## Headless usage

  Start an agent without a callback module for simple conversations:

      {:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-haiku-4-5"})
      :ok = Omni.Agent.prompt(agent, "Hello!")

  ## Events

  The listener process receives messages of the form `{:agent, pid, type, data}`
  where `type` is one of:

    - `:text_delta` — streaming text chunk
    - `:tool_result` — tool execution result
    - `:turn` — intermediate turn complete (agent continuing)
    - `:pause` — agent paused awaiting tool approval
    - `:done` — final turn complete (round finished)
    - `:error` — terminal error
    - `:cancelled` — cancelled
  """

  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}
  alias Omni.Response

  @doc "Called when the agent starts. Returns initial assigns."
  @callback init(opts :: keyword()) :: {:ok, assigns :: map()} | {:error, term()}

  @doc "Called when a step completes with a stop reason."
  @callback handle_stop(response :: Response.t(), state :: State.t()) ::
              {:stop, State.t()} | {:continue, term(), State.t()}

  @doc "Called for each tool use block to decide whether to execute, reject, or pause."
  @callback handle_tool_call(tool_use :: ToolUse.t(), state :: State.t()) ::
              {:execute, State.t()} | {:reject, term(), State.t()} | {:pause, State.t()}

  @doc "Called after each tool execution with the result, allowing modification."
  @callback handle_tool_result(result :: ToolResult.t(), state :: State.t()) ::
              {:ok, ToolResult.t(), State.t()}

  @doc "Called when a step-level LLM request fails."
  @callback handle_error(error :: term(), state :: State.t()) ::
              {:stop, State.t()} | {:retry, State.t()}

  @doc "Called when the GenServer terminates."
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

  @doc "Starts and links an agent process without a callback module."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    start_link(nil, opts)
  end

  @doc "Starts and links an agent process with the given callback module."
  @spec start_link(module() | nil, keyword()) :: GenServer.on_start()
  def start_link(module, opts) do
    {gs_opts, opts} = Keyword.split(opts, @genserver_keys)
    Omni.Agent.Server.start_link({module, opts}, gs_opts)
  end

  @doc """
  Sends a prompt to the agent.

  When idle, starts a new round and returns `:ok`.
  When running or paused, stages the prompt for the next turn boundary and
  returns `:ok`. A staged prompt takes effect after the current turn (or tool
  decision) completes, overriding `handle_stop`'s decision.
  """
  @spec prompt(GenServer.server(), term(), keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc """
  Resumes a paused agent with a tool decision.

  Accepts `:approve` to execute the pending tool, or `{:reject, reason}` to
  reject it with an error result. Returns `{:error, :not_paused}` if the agent
  is not paused.
  """
  @spec resume(GenServer.server(), :approve | {:reject, term()}) :: :ok | {:error, :not_paused}
  def resume(agent, decision) do
    GenServer.call(agent, {:resume, decision})
  end

  @doc "Cancels the current generation. Returns `:ok` or `{:error, :idle}`."
  @spec cancel(GenServer.server()) :: :ok | {:error, :idle}
  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc "Adds tools to the agent's context. Returns `:ok` or `{:error, :running}`."
  @spec add_tools(GenServer.server(), [Omni.Tool.t()]) :: :ok | {:error, :running}
  def add_tools(agent, tools) do
    GenServer.call(agent, {:add_tools, tools})
  end

  @doc "Removes tools by name from the agent's context. Returns `:ok` or `{:error, :running}`."
  @spec remove_tools(GenServer.server(), [String.t()]) :: :ok | {:error, :running}
  def remove_tools(agent, tool_names) do
    GenServer.call(agent, {:remove_tools, tool_names})
  end

  @doc "Clears conversation history and resets usage. Returns `:ok` or `{:error, :running}`."
  @spec clear(GenServer.server()) :: :ok | {:error, :running}
  def clear(agent) do
    GenServer.call(agent, :clear)
  end

  @doc "Sets the listener process for agent events. Returns `:ok` or `{:error, :running}`."
  @spec listen(GenServer.server(), pid()) :: :ok | {:error, :running}
  def listen(agent, pid) do
    GenServer.call(agent, {:listen, pid})
  end

  @doc "Returns the agent's model."
  @spec get_model(GenServer.server()) :: Omni.Model.t()
  def get_model(agent), do: GenServer.call(agent, :get_model)

  @doc "Returns the agent's conversation context."
  @spec get_context(GenServer.server()) :: Omni.Context.t()
  def get_context(agent), do: GenServer.call(agent, :get_context)

  @doc "Returns the agent's current status."
  @spec get_status(GenServer.server()) :: :idle | :running | :paused
  def get_status(agent), do: GenServer.call(agent, :get_status)

  @doc "Returns the agent's assigns map."
  @spec get_assigns(GenServer.server()) :: map()
  def get_assigns(agent), do: GenServer.call(agent, :get_assigns)

  @doc "Returns the agent's accumulated usage."
  @spec get_usage(GenServer.server()) :: Omni.Usage.t()
  def get_usage(agent), do: GenServer.call(agent, :get_usage)
end
