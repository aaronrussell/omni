defmodule Omni.Schema do
  @moduledoc """
  Builders and validation for JSON Schema maps.

  Each builder returns a plain map following JSON Schema conventions. Property
  keys are preserved as-is — use atoms for idiomatic Elixir, and JSON
  serialisation handles stringification on the wire.

  Option keywords accept snake_case and are normalized to camelCase JSON Schema
  keywords automatically (e.g. `min_length:` becomes `minLength`). Keys without
  a known mapping pass through unchanged.

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

  import Omni.Util, only: [maybe_put: 3]

  @doc "Builds a JSON Schema object type."
  @spec object(keyword()) :: map()
  def object(opts) when is_list(opts) do
    normalize_opts(opts) |> Map.put(:type, "object")
  end

  @doc "Builds a JSON Schema object with the given `properties` map."
  @spec object(map(), keyword()) :: map()
  def object(properties, opts \\ []) when is_map(properties) do
    Keyword.put(opts, :properties, properties) |> object()
  end

  @doc "Builds a JSON Schema string type."
  @spec string(keyword()) :: map()
  def string(opts \\ []) do
    normalize_opts(opts) |> Map.put(:type, "string")
  end

  @doc "Builds a JSON Schema number type."
  @spec number(keyword()) :: map()
  def number(opts \\ []) do
    normalize_opts(opts) |> Map.put(:type, "number")
  end

  @doc "Builds a JSON Schema integer type."
  @spec integer(keyword()) :: map()
  def integer(opts \\ []) do
    normalize_opts(opts) |> Map.put(:type, "integer")
  end

  @doc "Builds a JSON Schema boolean type."
  @spec boolean(keyword()) :: map()
  def boolean(opts \\ []) do
    normalize_opts(opts) |> Map.put(:type, "boolean")
  end

  @doc "Builds a JSON Schema array type."
  @spec array(keyword()) :: map()
  def array(opts) when is_list(opts) do
    normalize_opts(opts) |> Map.put(:type, "array")
  end

  @doc "Builds a JSON Schema array with the given `items` schema."
  @spec array(map(), keyword()) :: map()
  def array(items, opts \\ []) when is_map(items) do
    Keyword.put(opts, :items, items) |> array()
  end

  @doc "Builds a JSON Schema enum — a list of allowed literal values."
  @spec enum(list(), keyword()) :: map()
  def enum(values, opts \\ []) do
    normalize_opts(opts) |> Map.put(:enum, values)
  end

  @doc "Builds a JSON Schema `anyOf` — valid when at least one subschema matches."
  @spec any_of(list(map()), keyword()) :: map()
  def any_of(schemas, opts \\ []) when is_list(schemas) do
    normalize_opts(opts) |> Map.put(:anyOf, schemas)
  end

  @doc """
  Merges additional options into an existing schema map.

      Schema.string() |> Schema.update(min_length: 1, max_length: 100)
  """
  @spec update(map(), keyword()) :: map()
  def update(schema, opts) do
    Map.merge(schema, normalize_opts(opts))
  end

  @doc """
  Validates input against a schema.

  Enforces types, required fields, string constraints (`minLength`, `maxLength`,
  `pattern`), numeric constraints (`minimum`, `maximum`, `exclusiveMinimum`,
  `exclusiveMaximum`), and `anyOf` unions. Array item types are validated, but
  array-level constraints (`minItems`, `maxItems`, `uniqueItems`) and
  `multipleOf` are not — these are still sent to the LLM in the schema but
  skipped during local validation.

  Property key types are preserved: atom-keyed schemas validate and cast
  string-keyed JSON input back to atom keys, so validated output uses the same
  key types as the schema definition. Builder option keywords (e.g.
  `min_length:`) must be atoms.
  """
  @spec validate(map(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, input) do
    Peri.validate(to_peri(schema), input)
  end

  @doc false
  @spec format_errors(term()) :: String.t()
  def format_errors(errors) when is_list(errors) do
    errors
    |> flatten_errors([])
    |> Enum.map_join("\n", fn {path, message} ->
      "- #{Enum.join(path, ".")}: #{message}"
    end)
  end

  def format_errors(%{__struct__: _} = error), do: format_errors([error])

  defp flatten_errors([], acc), do: Enum.reverse(acc)

  defp flatten_errors([%{errors: nested} = _error | rest], acc)
       when is_list(nested) and nested != [] do
    flatten_errors(rest, Enum.reverse(flatten_errors(nested, [])) ++ acc)
  end

  defp flatten_errors([%{path: path, key: key, message: message} | rest], acc) do
    path_parts =
      case {path, key} do
        {nil, nil} -> []
        {nil, key} -> [to_string(key)]
        {path, _} -> Enum.map(path, &to_string/1)
      end

    flatten_errors(rest, [{path_parts, message} | acc])
  end

  defp flatten_errors([other | rest], acc) do
    flatten_errors(rest, [{[], inspect(other)} | acc])
  end

  defp to_peri(%{type: "object", properties: props} = schema) do
    required = MapSet.new(Map.get(schema, :required, []))

    Map.new(props, fn {key, value_schema} ->
      peri_type = to_peri(value_schema)
      type = if key in required, do: {:required, peri_type}, else: peri_type
      {key, type}
    end)
  end

  defp to_peri(%{type: "object"}), do: :map

  defp to_peri(%{type: "string"} = schema) do
    constrain(:string, string_constraints(schema))
  end

  defp to_peri(%{type: "number"} = schema) do
    case numeric_constraints(schema) do
      [] ->
        {:either, {:integer, :float}}

      constraints ->
        {:either,
         {
           constrain(:integer, constraints),
           constrain(:float, constraints)
         }}
    end
  end

  defp to_peri(%{type: "integer"} = schema) do
    constrain(:integer, numeric_constraints(schema))
  end

  defp to_peri(%{type: "boolean"}), do: :boolean
  defp to_peri(%{type: "array", items: items}), do: {:list, to_peri(items)}
  defp to_peri(%{type: "array"}), do: :list
  defp to_peri(%{enum: values}), do: {:enum, values}
  defp to_peri(%{anyOf: schemas}), do: {:oneof, Enum.map(schemas, &to_peri/1)}
  defp to_peri(_), do: :any

  # -- Peri constraint extraction --

  defp constrain(type, []), do: type
  defp constrain(type, [single]), do: {type, single}
  defp constrain(type, constraints), do: {type, constraints}

  defp string_constraints(schema) do
    []
    |> maybe_put(:min, schema[:minLength])
    |> maybe_put(:max, schema[:maxLength])
    |> maybe_put(:regex, compile_pattern(schema[:pattern]))
  end

  defp numeric_constraints(schema) do
    []
    |> maybe_put(:gte, schema[:minimum])
    |> maybe_put(:lte, schema[:maximum])
    |> maybe_put(:gt, schema[:exclusiveMinimum])
    |> maybe_put(:lt, schema[:exclusiveMaximum])
  end

  defp compile_pattern(nil), do: nil
  defp compile_pattern(pattern), do: Regex.compile!(pattern)

  # -- Key normalization --

  @key_map %{
    min_length: :minLength,
    max_length: :maxLength,
    min_items: :minItems,
    max_items: :maxItems,
    unique_items: :uniqueItems,
    multiple_of: :multipleOf,
    exclusive_minimum: :exclusiveMinimum,
    exclusive_maximum: :exclusiveMaximum,
    additional_properties: :additionalProperties,
    min_properties: :minProperties,
    max_properties: :maxProperties,
    pattern_properties: :patternProperties
  }

  defp normalize_opts(opts) do
    Map.new(opts, fn {k, v} -> {normalize_key(k), v} end)
  end

  defp normalize_key(key) when is_atom(key), do: Map.get(@key_map, key, key)
  defp normalize_key(key), do: key
end
