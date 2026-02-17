defmodule Omni.Tool do
  @moduledoc """
  A tool that can be invoked by an LLM during a conversation.

  Tools are defined as modules using `use Omni.Tool`, which injects the
  `Omni.Tool` behaviour and generates constructors that produce `%Omni.Tool{}`
  structs with a bound handler function.

  ## Stateless tools

  Define `schema/0` and `call/1`:

      defmodule MyApp.Tools.GetWeather do
        use Omni.Tool, name: "get_weather", description: "Gets the weather for a city"

        def schema do
          import Omni.Schema
          object(%{city: string(description: "City name")}, required: [:city])
        end

        def call(input) do
          "The weather in \#{input.city} is sunny"
        end
      end

  ## Stateful tools

  Define `schema/0`, `init/1`, and `call/2`:

      defmodule MyApp.Tools.DbLookup do
        use Omni.Tool, name: "db_lookup", description: "Looks up a record"

        def schema do
          import Omni.Schema
          object(%{id: integer()}, required: [:id])
        end

        def init(repo), do: repo

        def call(input, repo) do
          repo.get(Record, input.id)
        end
      end
  """

  @enforce_keys [:name, :description]
  defstruct [:name, :description, :input_schema, :handler]

  @typedoc "A tool struct with an optional handler function."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          handler: (map() -> term()) | nil
        }

  @doc "Creates a new tool struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Executes a tool's handler with the given input.

  If the tool has an `input_schema`, the input is validated and cast before
  calling the handler. Peri maps string-keyed LLM input to the key types used
  in the schema, so handlers receive atom keys when the schema uses atoms.

  Returns `{:ok, result}` on success, `{:error, errors}` on validation failure,
  or `{:error, exception}` if the handler raises.
  """
  @spec execute(t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{handler: handler, input_schema: schema}, input)
      when is_function(handler, 1) do
    with {:ok, validated} <- validate_input(schema, input) do
      {:ok, handler.(validated)}
    end
  rescue
    e -> {:error, e}
  end

  defp validate_input(nil, input), do: {:ok, input}

  defp validate_input(schema, input) do
    Peri.validate(Omni.Schema.to_peri(schema), input)
  end

  @callback schema() :: map()
  @callback init(params :: term()) :: term()
  @callback call(input :: map()) :: term()
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
