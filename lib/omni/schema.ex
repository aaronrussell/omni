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

  ## Custom validators

  For schemas that need richer semantics than the built-in Peri-backed
  validator provides — `$ref` resolution, `oneOf`/`allOf` combinators,
  custom casting — implement the `Omni.Schema.Adapter` behaviour and pass
  a `{module, state}` tuple anywhere a schema is accepted. See
  `Omni.Schema.Adapter` for a worked JSV example.

  This module is itself the default `Omni.Schema.Adapter` — `to_schema/1`
  and `validate/2` both implement the behaviour for raw JSON Schema maps,
  and dispatch to the relevant adapter when given an adapter tuple.
  """

  @behaviour Omni.Schema.Adapter

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

  @typedoc """
  A schema accepted anywhere Omni takes a JSON Schema. Either a raw map, or
  a `{module, state}` tuple where `module` implements `Omni.Schema.Adapter`.
  """
  @type t :: map() | {module(), term()}

  @doc """
  Returns the JSON Schema map sent on the wire for the given schema.

  When the schema is a raw map, returns it unchanged. When it is a
  `{module, state}` adapter tuple, calls `module.to_schema(state)`.

  Implements the `Omni.Schema.Adapter` behaviour for raw maps; delegates
  to the named module for adapter tuples.
  """
  @impl Omni.Schema.Adapter
  @spec to_schema(t()) :: map()
  def to_schema({mod, state}) when is_atom(mod), do: mod.to_schema(state)
  def to_schema(schema) when is_map(schema), do: schema

  @doc """
  Validates input against a schema.

  When the schema is a `{module, state}` adapter tuple, dispatches to the
  adapter's `validate/2`. When it is a raw map, runs the built-in validator
  (Peri-backed via `Peri.from_json_schema/1`).

  The built-in validator enforces JSON Schema constraints including types,
  required fields, string constraints (`minLength`, `maxLength`, `pattern`,
  `format`), numeric constraints (`minimum`, `maximum`, `exclusiveMinimum`,
  `exclusiveMaximum`, `multipleOf`), array constraints (`minItems`,
  `maxItems`, `uniqueItems`), enums, const literals, union types, and
  `anyOf`/`oneOf`/`allOf` combinators.

  Property key types are preserved: atom-keyed schemas validate and cast
  string-keyed JSON input back to atom keys, so validated output uses the
  same key types as the schema definition.

  Returns `{:ok, validated}` or `{:error, message}` with a human-readable
  error string.
  """
  @impl Omni.Schema.Adapter
  @spec validate(t(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate({mod, state}, input) when is_atom(mod) do
    mod.validate(state, input)
  end

  def validate(schema, input) when is_map(schema) do
    with {:ok, peri_schema} <- Peri.from_json_schema(normalize_schema(schema)),
         {:ok, validated} <- Peri.validate(restore_permissive(peri_schema), input) do
      {:ok, validated}
    else
      {:error, errors} -> {:error, format_errors(errors)}
    end
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

  # -- Schema normalization for Peri.from_json_schema/1 --
  #
  # Peri's converter requires fully string-keyed schemas with string-typed
  # values for `type`, `required`, etc. Our builders produce atom-keyed
  # maps with mostly string values, but users may pass either. Normalize
  # everything to JSON-shaped strings before conversion.
  #
  # JSON Schema's `number` type accepts integers, but Peri maps it to
  # `:float` (which rejects integers). Rewrite to a `["integer", "number"]`
  # union so both pass.

  defp normalize_schema(schema) do
    schema
    |> stringify()
    |> rewrite_number_type()
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    Atom.to_string(atom)
  end

  defp stringify(other), do: other

  defp stringify_key(k) when is_atom(k) and not is_nil(k) and not is_boolean(k) do
    Atom.to_string(k)
  end

  defp stringify_key(k), do: k

  defp rewrite_number_type(%{"type" => "number"} = schema) do
    schema
    |> Map.put("type", ["integer", "number"])
    |> rewrite_children()
  end

  defp rewrite_number_type(%{"type" => types} = schema) when is_list(types) do
    schema =
      if "number" in types and "integer" not in types do
        Map.put(schema, "type", ["integer" | types])
      else
        schema
      end

    rewrite_children(schema)
  end

  defp rewrite_number_type(map) when is_map(map), do: rewrite_children(map)
  defp rewrite_number_type(list) when is_list(list), do: Enum.map(list, &rewrite_number_type/1)
  defp rewrite_number_type(other), do: other

  defp rewrite_children(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, rewrite_number_type(v)} end)
  end

  # Peri's converter produces an empty map (`%{}`) for bare object schemas
  # without `properties` — which then drops every key on validate. Restore
  # the old behaviour: a bare object accepts any map. Walk recursively so
  # nested bare objects also become permissive.

  defp restore_permissive(%_{} = struct), do: struct
  defp restore_permissive(%{} = m) when map_size(m) == 0, do: :map

  defp restore_permissive(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, restore_permissive(v)} end)
  end

  defp restore_permissive(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&restore_permissive/1)
    |> List.to_tuple()
  end

  defp restore_permissive(list) when is_list(list), do: Enum.map(list, &restore_permissive/1)
  defp restore_permissive(other), do: other

  # -- Key normalization for builder option keywords --

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
