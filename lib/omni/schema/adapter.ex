defmodule Omni.Schema.Adapter do
  @moduledoc """
  A behaviour for validating schemas with a library of your choice.

  Omni's own validator (`Omni.Schema.validate/2`) is meant for schemas of
  simple shape, and lists where it stops. Write an adapter when a schema
  needs more, such as combinators, references or casting into your own
  types, or to validate with a library you already use, such as
  [JSV](https://hex.pm/packages/jsv).

  Wherever Omni takes a JSON Schema map (the `:output` option, a tool's
  `:input_schema`, a tool module's `schema/0`) it also takes a
  `{module, state}` tuple. The module implements this behaviour, and the
  state is whatever the adapter needs: a built validator, a struct.

  Omni calls `to_schema/1` for the JSON Schema map to send to the provider,
  and `validate/2` with the model's output or a tool's input.

  ## Example: a JSV adapter

  Omni does not ship this. Define it in your own application:

  ```elixir
  defmodule MyApp.JSVAdapter do
    @behaviour Omni.Schema.Adapter

    @impl true
    def to_schema(%JSV.Root{raw: raw}), do: raw

    @impl true
    def validate(%JSV.Root{} = root, input) do
      case JSV.validate(input, root) do
        {:ok, data} ->
          {:ok, data}

        {:error, %JSV.ValidationError{} = err} ->
          {:error, Exception.message(err)}
      end
    end
  end
  ```

  ## Using an adapter

  Build the state once and pass it in a tuple. A module attribute is
  evaluated at compile time, so the cost of building is paid once:

  ```elixir
  # Structured output
  @output_root JSV.build!(%{
    type: :object,
    properties: %{name: %{type: :string}},
    required: [:name]
  })

  Omni.generate_text(model, prompt,
    output: {MyApp.JSVAdapter, @output_root}
  )

  # Tool with adapter-validated input
  defmodule MyApp.Tools.Search do
    use Omni.Tool, name: "search", description: "Search the docs"

    @input_root JSV.build!(%{
      type: :object,
      properties: %{query: %{type: :string, minLength: 1}},
      required: [:query]
    })

    def schema, do: {MyApp.JSVAdapter, @input_root}

    def call(input) do
      MyApp.Docs.search(input["query"])
    end
  end
  ```

  An adapter decides the keys of the data it returns. JSV returns string
  keys, so the handler above reads `input["query"]`, where Omni's own
  validator would give it the schema's atom keys.
  """

  @doc """
  Returns the JSON Schema map for this adapter's state.

  Called when Omni builds a request, for the schema sent to the provider.
  The map must be JSON-encodable.
  """
  @callback to_schema(state :: term()) :: map()

  @doc """
  Validates input against the adapter's state.

  Called to validate structured output or a tool's input. Return
  `{:ok, value}` with the validated data, or `{:error, message}`.

  The value is what the caller gets: `response.output`, or the input handed
  to a tool's handler. An adapter may cast it on the way, for example
  turning string keys into atoms or maps into structs.

  The message goes back to the model, as a retry prompt for structured
  output or as an error result for a tool, so make it clear and short.
  """
  @callback validate(state :: term(), input :: term()) ::
              {:ok, term()} | {:error, String.t()}
end
