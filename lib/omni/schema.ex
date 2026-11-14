defmodule Omni.Schema do
  @moduledoc """
  Builders and validation for JSON Schema maps.

  Schemas describe a tool's input and structured output (the `:output`
  option). Each builder returns a plain map in JSON Schema form, so builders
  nest, and a map you write by hand works wherever a built one does.

  ```elixir
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
  ```

  ## Keys

  Property keys are kept as you write them. Write atoms, and validated data
  (a tool's input, `response.output`) comes back with atom keys, whatever
  the model sent.

  ## Options

  Every builder takes options, which become keywords of the schema:
  `description:`, `minimum:`, `default:` and so on. Keywords that JSON
  Schema spells in camelCase can be written in snake_case:

  ```elixir
  Omni.Schema.string(min_length: 1, max_length: 100)
  #=> %{type: "string", minLength: 1, maxLength: 100}
  ```

  These are `min_length`, `max_length`, `min_items`, `max_items`,
  `unique_items`, `multiple_of`, `exclusive_minimum`, `exclusive_maximum`,
  `additional_properties`, `min_properties`, `max_properties` and
  `pattern_properties`. Any other key passes through unchanged.

  ## Other validators

  Omni's own validator is deliberately small. It is meant for schemas of
  simple shape: objects, arrays and constrained values, which is what
  models handle best. `validate/2` lists what it checks and where it stops.

  For schemas that lean on combinators or references, or to use a JSON
  Schema library you already have, pass an `Omni.Schema.Adapter` tuple,
  `{module, state}`, wherever a schema is taken.
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

  @doc "Builds a JSON Schema enum: a list of allowed literal values."
  @spec enum(list(), keyword()) :: map()
  def enum(values, opts \\ []) do
    normalize_opts(opts) |> Map.put(:enum, values)
  end

  @doc "Builds a JSON Schema `anyOf`: valid when at least one subschema matches."
  @spec any_of(list(map()), keyword()) :: map()
  def any_of(schemas, opts \\ []) when is_list(schemas) do
    normalize_opts(opts) |> Map.put(:anyOf, schemas)
  end

  @doc """
  Merges additional options into an existing schema map.

  ```elixir
  Schema.string() |> Schema.update(min_length: 1, max_length: 100)
  ```
  """
  @spec update(map(), keyword()) :: map()
  def update(schema, opts) do
    Map.merge(schema, normalize_opts(opts))
  end

  @typedoc """
  A schema, as taken wherever Omni takes one.

  A JSON Schema map, or a `{module, state}` tuple whose module implements
  `Omni.Schema.Adapter`.
  """
  @type t :: map() | {module(), term()}

  @doc """
  Returns the JSON Schema map sent to the provider for a schema.

  A map is returned unchanged. An adapter tuple gives its module's
  `to_schema/1`.
  """
  @impl Omni.Schema.Adapter
  @spec to_schema(t()) :: map()
  def to_schema({mod, state}) when is_atom(mod), do: mod.to_schema(state)
  def to_schema(schema) when is_map(schema), do: schema

  @doc """
  Validates input against a schema.

  An adapter tuple is validated by its module's `validate/2`. A map is
  validated by Omni's own validator, built on
  [Peri](https://hex.pm/packages/peri), which checks:

  - types, union types and required fields
  - strings: `minLength`, `maxLength`, `pattern`, `format`
  - numbers: `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
    `multipleOf`
  - arrays: `minItems`, `maxItems`, `uniqueItems`
  - `enum` and `const`
  - `anyOf` and `oneOf`
  - `allOf`, over object schemas only
  - `$ref` to one of the schema's own `$defs`

  Validated data has the schema's keys: a schema written with atom keys
  turns string-keyed JSON back into atom keys. This follows `properties`
  and `items` only. An object reached through `anyOf`, `oneOf`, `allOf` or
  `$ref` keeps its string keys.

  Returns `{:ok, validated}`, or `{:error, message}` with a message fit to
  show the model.
  """
  @impl Omni.Schema.Adapter
  @spec validate(t(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate({mod, state}, input) when is_atom(mod) do
    mod.validate(state, input)
  end

  def validate(schema, input) when is_map(schema) do
    with {:ok, peri_schema} <- Peri.from_json_schema(stringify(schema), keys: :strings),
         {:ok, validated} <- Peri.validate(restore_permissive(peri_schema), input) do
      {:ok, recase(validated, schema)}
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

  # -- Schema preparation for Peri.from_json_schema/2 --
  #
  # Peri's converter requires fully string-keyed schemas with string values
  # for `type`, `required`, etc. The builders produce atom-keyed maps with
  # mostly string values, and users may pass either, so everything is
  # stringified before conversion. Booleans, nils and structs are left alone.

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

  # Peri's converter produces an empty map (`%{}`) for an object schema
  # without `properties`, which then drops every key on validate. These are
  # made permissive instead, nested ones included: a bare object accepts any
  # map.

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

  # -- Output re-keying --
  #
  # Peri returns string keys. The validated value is walked alongside the
  # original (pre-stringification) schema and re-keyed, so output key types
  # match the schema's property keys. An atom-keyed schema gives atom-keyed
  # output without any atom-table lookup.

  defp recase(value, schema) when is_map(schema) and is_map(value) do
    cond do
      Map.has_key?(schema, :properties) -> recase_object(value, schema.properties)
      Map.has_key?(schema, "properties") -> recase_object(value, schema["properties"])
      true -> value
    end
  end

  defp recase(value, schema) when is_map(schema) and is_list(value) do
    cond do
      Map.has_key?(schema, :items) -> Enum.map(value, &recase(&1, schema.items))
      Map.has_key?(schema, "items") -> Enum.map(value, &recase(&1, schema["items"]))
      true -> value
    end
  end

  defp recase(value, _schema), do: value

  defp recase_object(value, props) when is_map(props) do
    Map.new(value, fn {validated_key, v} ->
      {original_key, sub_schema} = lookup_property(props, validated_key)
      {original_key, recase(v, sub_schema)}
    end)
  end

  defp recase_object(value, _props), do: value

  # Looks up a property in the original schema's properties map. The
  # validated key is a string; the original may be an atom or a string.
  # Returns {key, sub_schema} with the key as the original schema has it.
  # Properties the schema doesn't list (additionalProperties) pass through
  # as strings.

  defp lookup_property(props, key) when is_binary(key) do
    cond do
      Map.has_key?(props, key) ->
        {key, Map.fetch!(props, key)}

      true ->
        case safe_existing_atom(key) do
          nil ->
            {key, %{}}

          atom ->
            if Map.has_key?(props, atom), do: {atom, Map.fetch!(props, atom)}, else: {key, %{}}
        end
    end
  end

  defp safe_existing_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

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
