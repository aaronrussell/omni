defmodule Omni.Schema.Adapter do
  @moduledoc """
  Behaviour for plugging in alternative schema validators.

  Omni's built-in `Omni.Schema` validator is a pragmatic Peri-backed
  implementation that covers the common JSON Schema cases. For schemas that
  need richer semantics — `$ref` resolution, `oneOf`/`allOf` combinators,
  custom casting, draft-2020-12 compliance — implement this behaviour to plug
  in a library like [JSV](https://hex.pm/packages/jsv).

  An adapter wraps both schema construction and validation. Anywhere Omni
  accepts a JSON Schema map (the `:output` option, a `Tool`'s
  `input_schema`, the `schema/0` callback in tool modules) it also accepts
  a `{module, state}` tuple where `module` implements this behaviour and
  `state` is whatever shape that adapter wants to hold (a built validator,
  a struct, a closure-bound resource).

  At wire-encoding time Omni calls `to_schema/1` to extract the JSON Schema
  map sent to the LLM. At validation time it calls `validate/2` with the
  LLM's response (or tool input).

  ## Example: a JSV adapter

  This is not shipped with Omni — implement it in your own application if
  you want JSV-backed validation.

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

  ## Using an adapter

  Build the validator state once and pass it as a tuple. Module attributes
  are evaluated at compile time, so the build cost is paid once per module
  load:

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

  Note: when an adapter returns string-keyed maps from validation (as JSV
  does), tool handlers must access input by string key rather than the
  atom-key default that Omni's built-in validator preserves.
  """

  @doc """
  Returns the JSON Schema map for this adapter's state.

  Called by Omni at request-build time when emitting the schema to the LLM
  on the wire. The returned map should be a plain JSON-encodable shape.
  """
  @callback to_schema(state :: term()) :: map()

  @doc """
  Validates input against the adapter's state.

  Called by Omni when validating structured output or tool input. Return
  `{:ok, value}` with the validated data, or `{:error, message}` with a
  human-readable error string.

  Adapters typically cast input to a normalised shape on success — for
  example, casting JSON string keys to atom keys (the built-in
  `Omni.Schema` validator), coercing values to typed structs (JSV with
  `defschema`), or transforming dates and decimals. The cast value
  becomes the structured output on `Response`, or the input map handed
  to a tool handler.

  The error string is sent back to the LLM during structured-output
  retries and back to the caller as a tool result on tool input
  failures, so favour clarity over detail.

  Argument order mirrors `Omni.Schema.validate/2`: state first (the
  schema-shaped thing), input second (the data being validated).
  """
  @callback validate(state :: term(), input :: term()) ::
              {:ok, term()} | {:error, String.t()}
end
