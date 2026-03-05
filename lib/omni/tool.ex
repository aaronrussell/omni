defmodule Omni.Tool do
  @moduledoc """
  Reusable, validated tools that an LLM can invoke during a conversation.

  Tools give the model access to external capabilities — looking up data,
  calling APIs, running computations. When the model decides to use a tool,
  Omni's loop automatically executes it and feeds the result back, continuing
  until the model produces a final text response.

  A tool is a `%Tool{}` struct with a name, description, optional input schema,
  and optional handler function. You can create one directly with `Omni.tool/1`
  for quick, inline use (see the Tools section in `Omni`), or define a tool
  module with `use Omni.Tool` to bundle the schema, handler, and metadata in a
  reusable unit.

  ## Defining a tool module

  A tool module implements `schema/0` and `call/1`:

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

  `schema/0` returns a plain map following JSON Schema conventions. The
  `Omni.Schema` helpers are a convenient way to build these, but any map with
  the right structure works — you can construct schemas by hand or with other
  libraries. Import `Omni.Schema` inside the callback if you use it — it is
  not auto-imported by `use Omni.Tool`.

  `call/1` receives the validated input with atom keys matching the schema,
  regardless of the string keys the LLM sends. Return any term — it will be
  serialized and sent back to the model as a tool result.

  ## Stateful tools

  When a tool needs runtime state (a database connection, configuration, an
  API client), implement `init/1` and `call/2`:

      defmodule MyApp.Tools.DbLookup do
        use Omni.Tool, name: "db_lookup", description: "Looks up a record by ID"

        def schema do
          import Omni.Schema
          object(%{id: integer()}, required: [:id])
        end

        def init(repo), do: repo

        def call(input, repo) do
          repo.get(Record, input.id)
        end
      end

  `init/1` receives the argument passed to `new/1` and returns the state.
  `call/2` receives validated input and that state. The state is captured in
  a closure at construction time, so each `new/1` call can bind different state.

  ## Using tools

  Pass tool structs in the context:

      weather = MyApp.Tools.GetWeather.new()
      db_lookup = MyApp.Tools.DbLookup.new(MyApp.Repo)

      context = Omni.context(
        messages: [Omni.message("What's the weather in Paris?")],
        tools: [weather, db_lookup]
      )

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, context)

  The loop executes tool uses automatically and continues the conversation
  until the model responds with text (or hits `:max_steps`).

  ## Schema-only tools

  A `%Tool{}` struct with `handler: nil` defines a tool the model can invoke
  but Omni won't auto-execute. The loop breaks and returns the response
  containing `ToolUse` blocks for you to handle manually. This is useful when
  tool execution requires human approval or happens outside your application.

      schema = Omni.Schema.object(%{query: Omni.Schema.string()}, required: [:query])
      tool = Omni.tool(name: "search", description: "Web search", input_schema: schema)

  ## How execution works

  Calling `new/0` or `new/1` on a tool module:

  1. Calls `init/1` with the given argument (defaults to `nil`)
  2. Calls `schema/0` to capture the input schema
  3. Returns a `%Tool{}` struct with a handler closure bound to the init state

  When the model invokes the tool, `execute/2` validates the LLM's
  string-keyed input against the schema (via `Omni.Schema.validate/2`), casts
  keys to match the schema's key types, then calls the handler. Direct handler
  calls (`tool.handler.(input)`) bypass this validation.
  """

  @enforce_keys [:name, :description]
  defstruct [:name, :description, :input_schema, :handler]

  @typedoc """
  A tool struct.

  When `handler` is `nil`, the tool is schema-only — the loop will break and
  return `ToolUse` blocks for manual handling instead of auto-executing.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          handler: (map() -> term()) | nil
        }

  @doc """
  Creates a bare tool struct from a keyword list or map.

  This is a low-level constructor — it does not bind a handler closure or
  validate fields. Prefer `Omni.tool/1` for inline tools or `YourModule.new/0`
  for tool modules.
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Executes a tool's handler with the given input.

  If the tool has an `input_schema`, the input is validated and cast before
  calling the handler. Peri maps string-keyed LLM input to the key types used
  in the schema, so handlers receive atom keys when the schema uses atoms.
  When `input_schema` is `nil`, input is passed through to the handler as-is.

  Returns `{:ok, result}` on success, `{:error, errors}` on validation failure,
  or `{:error, exception}` if the handler raises.

  Raises `FunctionClauseError` if the tool has no handler (`handler: nil`).
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
  Returns a JSON Schema map describing the tool's input parameters.

  The return value is a plain map following JSON Schema conventions — you can
  build it with `Omni.Schema` helpers, construct it by hand, or use any other
  library. If using `Omni.Schema`, import it inside the callback body — it is
  not auto-imported by `use Omni.Tool`.

      def schema do
        import Omni.Schema
        object(%{city: string(description: "City name")}, required: [:city])
      end
  """
  @callback schema() :: map()

  @doc """
  Initializes state for a stateful tool.

  Called once by `new/1` at construction time. The argument is whatever was
  passed to `new/1` (defaults to `nil` for `new/0`). The return value becomes
  the second argument to `call/2`.

  The default implementation returns `nil`.
  """
  @callback init(params :: term()) :: term()

  @doc """
  Handles a tool invocation (stateless).

  Receives the validated input map with keys matching the schema. Return any
  term — it will be serialized and sent back to the model as a tool result.

  Implement either `call/1` or `call/2`, not both. The default `call/2`
  delegates to `call/1`, ignoring state.
  """
  @callback call(input :: map()) :: term()

  @doc """
  Handles a tool invocation with state (stateful).

  Same as `call/1`, but receives the state returned by `init/1` as the second
  argument. Implement this instead of `call/1` when the tool needs runtime
  state.
  """
  @callback call(input :: map(), state :: term()) :: term()

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    quote do
      @behaviour Omni.Tool

      @doc false
      def name, do: unquote(name)

      @doc false
      def description, do: unquote(description)

      @impl Omni.Tool
      def init(_params), do: nil

      @impl Omni.Tool
      def call(_input), do: raise("#{__MODULE__} must implement call/1 or call/2")

      @impl Omni.Tool
      def call(input, _state), do: call(input)

      @doc "Builds a `%Omni.Tool{}` struct with a bound handler."
      def new(params \\ nil) do
        state = init(params)

        %Omni.Tool{
          name: name(),
          description: description(),
          input_schema: schema(),
          handler: fn input -> call(input, state) end
        }
      end

      defoverridable init: 1, call: 1, call: 2
    end
  end
end
