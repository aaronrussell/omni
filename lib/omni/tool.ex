defmodule Omni.Tool do
  @moduledoc """
  A tool the model can use during a conversation.

  A tool has a name, a description that tells the model when to use it, a
  schema for its input, and a handler that does the work. Put tools in a
  context and Omni runs the ones the model uses, sending the results back
  until the model answers. [Tools](text-generation.md#tools) introduces
  them.

  There are two ways to make one. `Omni.tool/1` builds a tool inline from a
  name, description, schema and function. `use Omni.Tool` defines a tool
  module, which keeps those together in one reusable place and is what
  most of this page is about.

  ## Struct fields

  - `:name` - the name the model uses the tool by
  - `:description` - what the tool does and when to use it, for the model
  - `:input_schema` - a JSON Schema map for the input, an
    `Omni.Schema.Adapter` tuple, or `nil` for a tool that takes none
  - `:handler` - a one-argument function called with the validated input,
    or `nil` for a tool Omni does not run (see
    [Tools without a handler](#module-tools-without-a-handler))

  ## Tool modules

  A tool module implements `schema/0` and `call/1`:

  ```elixir
  defmodule MyApp.Tools.GetWeather do
    use Omni.Tool, name: "get_weather", description: "Gets the weather for a city"

    def schema do
      import Omni.Schema
      object(%{city: string(description: "City name")}, required: [:city])
    end

    def call(input) do
      WeatherAPI.fetch(input.city)
    end
  end
  ```

  `schema/0` returns a JSON Schema map. The `Omni.Schema` builders are a
  convenient way to write one, and any map of the right shape works. Import
  `Omni.Schema` inside the callback: `use Omni.Tool` does not import it.

  `call/1` receives the validated input with the schema's own keys, whatever
  the model sent. It may return any term.

  The module gains `new/0` and `new/1`, which build the tool struct to put
  in a context:

  ```elixir
  Omni.context(messages: messages, tools: [MyApp.Tools.GetWeather.new()])
  ```

  ## Tools with state

  When a tool needs something at runtime (a database connection, an API
  client, configuration), implement `init/1` and `call/2`:

  ```elixir
  defmodule MyApp.Tools.DbLookup do
    use Omni.Tool, name: "db_lookup", description: "Looks up a record by id"

    def schema do
      import Omni.Schema
      object(%{id: integer()}, required: [:id])
    end

    def init(repo), do: repo

    def call(input, repo) do
      repo.get(Record, input.id)
    end
  end

  tool = MyApp.Tools.DbLookup.new(MyApp.Repo)
  ```

  `init/1` receives the argument given to `new/1` and returns the state.
  `call/2` receives the input and that state. Each `new/1` binds its own
  state, so one module can make several differently configured tools.

  The description and the schema can depend on the state too. Implement
  `description/1` or `schema/1` in place of the zero-argument callback:

  ```elixir
  defmodule MyApp.Tools.SetMode do
    use Omni.Tool, name: "set_mode"

    def init(modes), do: modes

    def description(modes), do: "Switches the assistant's mode to one of: " <> Enum.join(modes, ", ")

    def schema(modes) do
      import Omni.Schema
      object(%{mode: enum(modes)}, required: [:mode])
    end

    def call(input, _modes), do: {:ok, input.mode}
  end

  tool = MyApp.Tools.SetMode.new(["focus", "casual", "technical"])
  ```

  ## Name and description as callbacks

  The `name:` and `description:` options to `use Omni.Tool` are shorthand
  for the `name/0` and `description/0` callbacks. Leave an option out and
  implement the callback yourself:

  ```elixir
  defmodule MyApp.Tools.Ping do
    use Omni.Tool

    def name, do: "ping"
    def description, do: "Returns pong"
    def schema, do: Omni.Schema.object(%{})
    def call(_input), do: "pong"
  end
  ```

  ## Tools without a handler

  A tool with `handler: nil` is one the model may use but Omni won't run.
  The loop stops and the response comes back with `stop_reason: :tool_use`
  and the `Omni.Content.ToolUse` blocks for you to answer. This suits tools
  that need a person's approval, or that run somewhere else (see
  [Running tools yourself](text-generation.md#running-tools-yourself)).

  ```elixir
  schema = Omni.Schema.object(%{query: Omni.Schema.string()}, required: [:query])
  tool = Omni.tool(name: "search", description: "Web search", input_schema: schema)
  ```

  ## Other schema validators

  Where Omni's own validator isn't enough, a schema can be an
  `Omni.Schema.Adapter` tuple, which validates with a library of your
  choice:

  ```elixir
  def schema, do: {MyApp.JSVAdapter, @input_root}
  ```

  An adapter decides the keys of the input it returns. One that returns
  string keys, as JSV does, hands your `call/1` string keys.

  ## How a tool runs

  `new/1` on a tool module calls `init/1` with its argument (`[]` for
  `new/0`), then `description/1` and `schema/1` with the state, and returns
  a tool struct whose handler is bound to that state.

  When the model uses the tool, `execute/2` validates the input against the
  schema, casts its keys to the schema's, and calls the handler. Calling
  `tool.handler` directly skips the validation.

  The result goes back to the model as text: a string as it is, anything
  else as JSON. Invalid input, a handler that raises and a tool that
  outruns `:tool_timeout` each become an error result the model can read
  and recover from. `Omni.Tool.Runner` does this part.
  """

  @enforce_keys [:name, :description]
  defstruct [:name, :description, :input_schema, :handler]

  @typedoc """
  A tool.

  See [Struct fields](#module-struct-fields).
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: Omni.Schema.t() | nil,
          handler: (map() -> term()) | nil
        }

  @doc """
  Creates a tool from a keyword list or map.

  `Omni.tool/1` is the same function. For a tool module, call the module's
  own `new/0` or `new/1`, which binds the handler to its state.

  ```elixir
  Omni.Tool.new(
    name: "search",
    description: "Searches the web",
    input_schema: Omni.Schema.object(%{query: Omni.Schema.string()}, required: [:query]),
    handler: fn input -> do_search(input.query) end
  )
  ```
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Runs a tool's handler with the given input.

  The input is validated against the tool's schema first, and its keys cast
  to the schema's, so a schema written with atom keys gives the handler
  atom keys. A tool with no schema passes the input through as it is.

  Returns `{:ok, result}`, `{:error, message}` when the input is invalid, or
  `{:error, exception}` when the handler raises.

  Raises `FunctionClauseError` if the tool has no handler.
  """
  @spec execute(t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{handler: handler, input_schema: schema}, input)
      when is_function(handler, 1) do
    with {:ok, validated} <- validate_input(schema, input) do
      try do
        {:ok, handler.(validated)}
      rescue
        e -> {:error, e}
      end
    end
  end

  defp validate_input(nil, input), do: {:ok, input}

  defp validate_input(schema, input) do
    Omni.Schema.validate(schema, input)
  end

  @doc """
  Returns the tool's name.

  Defaults to the `name:` option of `use Omni.Tool`. Implement it when you
  leave the option out.
  """
  @callback name() :: String.t()

  @doc """
  Returns the tool's description.

  Defaults to the `description:` option of `use Omni.Tool`. Implement it
  when you leave the option out.
  """
  @callback description() :: String.t()

  @doc """
  Returns the tool's description, given the tool's state.

  Called by `new/1` with the state `init/1` returned. The default calls
  `description/0`. Implement it when the description depends on the state
  (see [Tools with state](#module-tools-with-state)).
  """
  @callback description(state :: term()) :: String.t()

  @doc """
  Returns the tool's input schema.

  Returns a JSON Schema map, or an `Omni.Schema.Adapter` tuple
  `{module, state}`. To use the `Omni.Schema` builders, import them inside
  the callback: `use Omni.Tool` does not.

  ```elixir
  def schema do
    import Omni.Schema
    object(%{city: string(description: "City name")}, required: [:city])
  end
  ```

  Implement `schema/1` instead when the schema depends on the tool's state.
  """
  @callback schema() :: Omni.Schema.t()

  @doc """
  Returns the tool's input schema, given the tool's state.

  Called by `new/1` with the state `init/1` returned. The default calls
  `schema/0`. Implement it when the schema depends on the state, such as an
  enum of values read from configuration (see
  [Tools with state](#module-tools-with-state)).
  """
  @callback schema(state :: term()) :: Omni.Schema.t()

  @doc """
  Builds the tool's state.

  Called once by `new/1`, with the argument given to it (`[]` for `new/0`).
  What it returns is passed to `call/2`, `description/1` and `schema/1`.

  The default returns its argument.
  """
  @callback init(params :: term()) :: term()

  @doc """
  Runs the tool.

  Receives the validated input, with the schema's keys. Return any term: a
  string goes back to the model as it is, anything else as JSON.

  Implement `call/1` or `call/2`, not both. The default `call/2` calls
  `call/1`.
  """
  @callback call(input :: map()) :: term()

  @doc """
  Runs the tool, given the tool's state.

  As `call/1`, with the state `init/1` returned as the second argument.
  """
  @callback call(input :: map(), state :: term()) :: term()

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)

    name_default =
      if name do
        quote do
          @impl Omni.Tool
          @doc false
          def name, do: unquote(name)
        end
      end

    description_default =
      if description do
        quote do
          @impl Omni.Tool
          @doc false
          def description, do: unquote(description)
        end
      else
        quote do
          @impl Omni.Tool
          @doc false
          def description,
            do: raise("#{__MODULE__} must implement description/0 or description/1")
        end
      end

    overridable =
      [
        {:init, 1},
        {:call, 1},
        {:call, 2},
        {:description, 0},
        {:description, 1},
        {:schema, 0},
        {:schema, 1}
      ] ++ if(name, do: [{:name, 0}], else: [])

    quote do
      @behaviour Omni.Tool

      unquote(name_default)
      unquote(description_default)

      @impl Omni.Tool
      def init(params), do: params

      @impl Omni.Tool
      def description(_state), do: description()

      @impl Omni.Tool
      def schema, do: raise("#{__MODULE__} must implement schema/0 or schema/1")

      @impl Omni.Tool
      def schema(_state), do: schema()

      @impl Omni.Tool
      def call(_input), do: raise("#{__MODULE__} must implement call/1 or call/2")

      @impl Omni.Tool
      def call(input, _state), do: call(input)

      @doc "Builds the tool, binding its handler to the state `init/1` returns."
      def new(params \\ []) do
        state = init(params)

        %Omni.Tool{
          name: name(),
          description: description(state),
          input_schema: schema(state),
          handler: fn input -> call(input, state) end
        }
      end

      defoverridable unquote(overridable)
    end
  end
end
