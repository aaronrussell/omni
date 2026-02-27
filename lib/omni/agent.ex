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
          {:stop, %{state | assigns: Map.put(state.assigns, :last_response, response)}}
        end
      end

      {:ok, agent} = MyAgent.start_link(model: {:anthropic, "claude-haiku-4-5"})

  ## Headless usage

  Start an agent without a callback module for simple conversations:

      {:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-haiku-4-5"})
      :ok = Omni.Agent.prompt(agent, "Hello!")

  ## Events

  The listener process receives messages of the form `{:agent, pid, type, data}`
  where `type` is a streaming event type (`:text_delta`, `:tool_use_start`, etc.)
  or a lifecycle event (`:done`, `:error`, `:cancelled`).
  """

  alias Omni.Agent.State
  alias Omni.Response

  @doc "Called when the agent starts. Returns initial assigns."
  @callback init(opts :: keyword()) :: {:ok, assigns :: map()} | {:error, term()}

  @doc "Called when a step completes with a stop reason."
  @callback handle_stop(response :: Response.t(), state :: State.t()) :: {:stop, State.t()}

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
      def terminate(_reason, _state), do: :ok

      @doc "Starts and links an agent process with this callback module."
      def start_link(opts) do
        Omni.Agent.start_link(__MODULE__, opts)
      end

      defoverridable init: 1, handle_stop: 2, terminate: 2, start_link: 1
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

  @doc "Sends a prompt to the agent. Returns `:ok` or `{:error, :running}`."
  @spec prompt(GenServer.server(), term(), keyword()) :: :ok | {:error, :running}
  def prompt(agent, content, opts \\ []) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc "Cancels the current generation. Returns `:ok` or `{:error, :idle}`."
  @spec cancel(GenServer.server()) :: :ok | {:error, :idle}
  def cancel(agent) do
    GenServer.call(agent, :cancel)
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
  @spec get_status(GenServer.server()) :: :idle | :running
  def get_status(agent), do: GenServer.call(agent, :get_status)

  @doc "Returns the agent's assigns map."
  @spec get_assigns(GenServer.server()) :: map()
  def get_assigns(agent), do: GenServer.call(agent, :get_assigns)

  @doc "Returns the agent's accumulated usage."
  @spec get_usage(GenServer.server()) :: Omni.Usage.t()
  def get_usage(agent), do: GenServer.call(agent, :get_usage)
end
