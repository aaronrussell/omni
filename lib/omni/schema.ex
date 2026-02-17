defmodule Omni.Schema do
  @moduledoc """
  Functions for building JSON Schema maps.

  Each function returns a plain map following JSON Schema conventions. Property
  keys are preserved as-is — use atoms for idiomatic Elixir, and JSON
  serialisation will handle stringification when sending over the wire.

  When a tool is executed via `Omni.Tool.execute/2`, the schema is converted to
  a Peri validation schema and input is validated automatically. Peri maps
  string-keyed LLM input back to the key types used in the schema, so handlers
  receive atom keys if the schema was defined with atoms.

  ## Example

      iex> Omni.Schema.object(%{
      ...>   city: Omni.Schema.string(description: "City name"),
      ...>   temp: Omni.Schema.number()
      ...> }, required: [:city])
      %{
        type: "object",
        properties: %{
          city: %{type: "string", description: "City name"},
          temp: %{type: "number"}
        },
        required: [:city]
      }
  """

  @doc "Builds a JSON Schema object with the given properties."
  @spec object(map(), keyword()) :: map()
  def object(properties, opts \\ []) do
    Map.new(opts)
    |> Map.merge(%{type: "object", properties: properties})
  end

  @doc "Builds a JSON Schema string type."
  @spec string(keyword()) :: map()
  def string(opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "string"})
  end

  @doc "Builds a JSON Schema number type."
  @spec number(keyword()) :: map()
  def number(opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "number"})
  end

  @doc "Builds a JSON Schema integer type."
  @spec integer(keyword()) :: map()
  def integer(opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "integer"})
  end

  @doc "Builds a JSON Schema boolean type."
  @spec boolean(keyword()) :: map()
  def boolean(opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "boolean"})
  end

  @doc "Builds a JSON Schema array type with the given items schema."
  @spec array(map(), keyword()) :: map()
  def array(items, opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "array", items: items})
  end

  @doc "Builds a JSON Schema string type constrained to the given values."
  @spec enum(list(String.t()), keyword()) :: map()
  def enum(values, opts \\ []) do
    Map.new(opts) |> Map.merge(%{type: "string", enum: values})
  end

  @doc """
  Converts a JSON Schema map to a Peri validation schema.

  Used internally by `Omni.Tool.execute/2` to validate LLM-provided input
  against a tool's schema before calling its handler. Property keys are
  preserved as-is — Peri handles mapping string-keyed input to atom keys.
  """
  @spec to_peri(map()) :: term()
  def to_peri(%{type: "object", properties: props} = schema) do
    required = MapSet.new(Map.get(schema, :required, []))

    Map.new(props, fn {key, value_schema} ->
      peri_type = to_peri(value_schema)
      type = if key in required, do: {:required, peri_type}, else: peri_type
      {key, type}
    end)
  end

  def to_peri(%{type: "string", enum: values}), do: {:enum, values}
  def to_peri(%{type: "string"}), do: :string
  def to_peri(%{type: "number"}), do: {:either, {:integer, :float}}
  def to_peri(%{type: "integer"}), do: :integer
  def to_peri(%{type: "boolean"}), do: :boolean
  def to_peri(%{type: "array", items: items}), do: {:list, to_peri(items)}
end
