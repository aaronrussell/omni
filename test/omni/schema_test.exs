defmodule Omni.SchemaTest do
  use ExUnit.Case, async: true

  alias Omni.Schema

  describe "string/1" do
    test "returns string type" do
      assert Schema.string() == %{type: "string"}
    end

    test "merges opts" do
      result = Schema.string(description: "A city name", min_length: 1)
      assert result.type == "string"
      assert result.description == "A city name"
      assert result.minLength == 1
    end
  end

  describe "number/1" do
    test "returns number type" do
      assert Schema.number() == %{type: "number"}
    end

    test "merges opts" do
      assert Schema.number(minimum: 0) == %{type: "number", minimum: 0}
    end
  end

  describe "integer/1" do
    test "returns integer type" do
      assert Schema.integer() == %{type: "integer"}
    end

    test "merges opts" do
      assert Schema.integer(maximum: 100) == %{type: "integer", maximum: 100}
    end
  end

  describe "boolean/1" do
    test "returns boolean type" do
      assert Schema.boolean() == %{type: "boolean"}
    end
  end

  describe "enum/2" do
    test "returns enum constraint without hardcoded type" do
      result = Schema.enum(["red", "green", "blue"])
      assert result == %{enum: ["red", "green", "blue"]}
    end

    test "merges opts" do
      result = Schema.enum(["a", "b"], description: "Pick one")
      assert result.description == "Pick one"
      assert result.enum == ["a", "b"]
    end
  end

  describe "array/1,2" do
    test "nests the items schema" do
      result = Schema.array(Schema.string())
      assert result == %{type: "array", items: %{type: "string"}}
    end

    test "merges opts" do
      result = Schema.array(Schema.integer(), min_items: 1)
      assert result.type == "array"
      assert result.items == %{type: "integer"}
      assert result.minItems == 1
    end

    test "builds free-form array without items" do
      assert Schema.array([]) == %{type: "array"}
    end
  end

  describe "object/1,2" do
    test "preserves atom property keys" do
      result = Schema.object(%{name: Schema.string(), age: Schema.integer()})

      assert result.type == "object"
      assert result.properties.name == %{type: "string"}
      assert result.properties.age == %{type: "integer"}
    end

    test "preserves string property keys" do
      result = Schema.object(%{"name" => Schema.string()})
      assert result.properties["name"] == %{type: "string"}
    end

    test "handles required option" do
      result = Schema.object(%{city: Schema.string()}, required: [:city])
      assert result.required == [:city]
    end

    test "works without options" do
      result = Schema.object(%{ok: Schema.boolean()})

      assert result == %{
               type: "object",
               properties: %{ok: %{type: "boolean"}}
             }
    end

    test "builds free-form object without properties" do
      assert Schema.object([]) == %{type: "object"}
    end

    test "composes nested schemas" do
      result =
        Schema.object(%{
          tags: Schema.array(Schema.string()),
          status: Schema.enum(["active", "inactive"])
        })

      assert result.properties.tags == %{type: "array", items: %{type: "string"}}
      assert result.properties.status == %{enum: ["active", "inactive"]}
    end
  end

  describe "any_of/2" do
    test "builds anyOf schema" do
      result = Schema.any_of([Schema.string(), Schema.integer()])
      assert result == %{anyOf: [%{type: "string"}, %{type: "integer"}]}
    end

    test "merges opts" do
      result = Schema.any_of([Schema.string(), Schema.integer()], description: "A value")
      assert result.description == "A value"
      assert result.anyOf == [%{type: "string"}, %{type: "integer"}]
    end
  end

  describe "key normalization" do
    test "normalizes snake_case to camelCase in string opts" do
      result = Schema.string(min_length: 1, max_length: 100)
      assert result == %{type: "string", minLength: 1, maxLength: 100}
    end

    test "normalizes snake_case to camelCase in array opts" do
      result = Schema.array(Schema.string(), min_items: 1, unique_items: true)
      assert result == %{type: "array", items: %{type: "string"}, minItems: 1, uniqueItems: true}
    end

    test "normalizes snake_case to camelCase in object opts" do
      result = Schema.object(%{}, additional_properties: false)
      assert result == %{type: "object", properties: %{}, additionalProperties: false}
    end

    test "normalizes snake_case to camelCase in number opts" do
      result = Schema.number(multiple_of: 0.5, exclusive_minimum: 0, exclusive_maximum: 100)

      assert result == %{
               type: "number",
               multipleOf: 0.5,
               exclusiveMinimum: 0,
               exclusiveMaximum: 100
             }
    end

    test "passes unknown atom keys through unchanged" do
      result = Schema.string(description: "test", foo: "bar")
      assert result == %{type: "string", description: "test", foo: "bar"}
    end

    test "already-camelCase keys pass through unchanged" do
      result = Schema.string(minLength: 1)
      assert result == %{type: "string", minLength: 1}
    end
  end

  describe "update/2" do
    test "merges normalized opts into schema" do
      result = Schema.string() |> Schema.update(min_length: 1, max_length: 100)
      assert result == %{type: "string", minLength: 1, maxLength: 100}
    end

    test "overwrites existing keys" do
      result = Schema.string(description: "old") |> Schema.update(description: "new")
      assert result == %{type: "string", description: "new"}
    end

    test "passes unknown keys through" do
      result = Schema.integer() |> Schema.update(foo: "bar")
      assert result == %{type: "integer", foo: "bar"}
    end
  end

  describe "validate/2" do
    test "validates string input" do
      assert {:ok, "hello"} = Schema.validate(Schema.string(), "hello")
    end

    test "rejects invalid string input" do
      assert {:error, _} = Schema.validate(Schema.string(), 123)
    end

    test "validates integer input" do
      assert {:ok, 42} = Schema.validate(Schema.integer(), 42)
    end

    test "validates number input as integer" do
      assert {:ok, 42} = Schema.validate(Schema.number(), 42)
    end

    test "validates number input as float" do
      assert {:ok, 3.14} = Schema.validate(Schema.number(), 3.14)
    end

    test "validates boolean input" do
      assert {:ok, true} = Schema.validate(Schema.boolean(), true)
    end

    test "validates enum input" do
      schema = Schema.enum(["a", "b", "c"])
      assert {:ok, "a"} = Schema.validate(schema, "a")
      assert {:error, _} = Schema.validate(schema, "z")
    end

    test "validates array input" do
      schema = Schema.array(Schema.string())
      assert {:ok, ["a", "b"]} = Schema.validate(schema, ["a", "b"])
      assert {:error, _} = Schema.validate(schema, [1, 2])
    end

    test "validates object with required fields" do
      schema = Schema.object(%{city: Schema.string()}, required: [:city])
      assert {:ok, %{city: "Paris"}} = Schema.validate(schema, %{"city" => "Paris"})
      assert {:error, _} = Schema.validate(schema, %{})
    end

    test "validates nested objects" do
      schema =
        Schema.object(%{
          address: Schema.object(%{zip: Schema.string()}, required: [:zip])
        })

      input = %{"address" => %{"zip" => "12345"}}
      assert {:ok, %{address: %{zip: "12345"}}} = Schema.validate(schema, input)
    end

    test "enforces string minLength" do
      schema = Schema.string(min_length: 3)
      assert {:ok, "abc"} = Schema.validate(schema, "abc")
      assert {:error, _} = Schema.validate(schema, "ab")
    end

    test "enforces string maxLength" do
      schema = Schema.string(max_length: 5)
      assert {:ok, "hello"} = Schema.validate(schema, "hello")
      assert {:error, _} = Schema.validate(schema, "toolong")
    end

    test "enforces string pattern" do
      schema = Schema.string(pattern: "^\\d+$")
      assert {:ok, "123"} = Schema.validate(schema, "123")
      assert {:error, _} = Schema.validate(schema, "abc")
    end

    test "enforces combined string constraints" do
      schema = Schema.string(min_length: 2, max_length: 5)
      assert {:ok, "abc"} = Schema.validate(schema, "abc")
      assert {:error, _} = Schema.validate(schema, "a")
      assert {:error, _} = Schema.validate(schema, "toolong")
    end

    test "enforces integer minimum and maximum" do
      schema = Schema.integer(minimum: 1, maximum: 10)
      assert {:ok, 5} = Schema.validate(schema, 5)
      assert {:ok, 1} = Schema.validate(schema, 1)
      assert {:ok, 10} = Schema.validate(schema, 10)
      assert {:error, _} = Schema.validate(schema, 0)
      assert {:error, _} = Schema.validate(schema, 11)
    end

    test "enforces integer exclusiveMinimum and exclusiveMaximum" do
      schema = Schema.integer(exclusive_minimum: 0, exclusive_maximum: 10)
      assert {:ok, 1} = Schema.validate(schema, 1)
      assert {:error, _} = Schema.validate(schema, 0)
      assert {:error, _} = Schema.validate(schema, 10)
    end

    test "enforces number minimum as integer" do
      schema = Schema.number(minimum: 0)
      assert {:ok, 0} = Schema.validate(schema, 0)
      assert {:ok, 5} = Schema.validate(schema, 5)
      assert {:error, _} = Schema.validate(schema, -1)
    end

    test "enforces number minimum as float" do
      schema = Schema.number(minimum: 0)
      assert {:ok, val} = Schema.validate(schema, 0.0)
      assert val == 0.0
      assert {:ok, 1.5} = Schema.validate(schema, 1.5)
      assert {:error, _} = Schema.validate(schema, -0.1)
    end

    test "enforces constraints on object properties" do
      schema =
        Schema.object(
          %{name: Schema.string(min_length: 1), age: Schema.integer(minimum: 0)},
          required: [:name, :age]
        )

      assert {:ok, %{name: "A", age: 0}} = Schema.validate(schema, %{"name" => "A", "age" => 0})
      assert {:error, _} = Schema.validate(schema, %{"name" => "", "age" => 0})
      assert {:error, _} = Schema.validate(schema, %{"name" => "A", "age" => -1})
    end

    test "validates any_of accepting matching types" do
      schema = Schema.any_of([Schema.string(), Schema.integer()])
      assert {:ok, "hello"} = Schema.validate(schema, "hello")
      assert {:ok, 42} = Schema.validate(schema, 42)
      assert {:error, _} = Schema.validate(schema, true)
    end

    test "validates any_of in object properties" do
      schema =
        Schema.object(
          %{value: Schema.any_of([Schema.string(), Schema.integer()])},
          required: [:value]
        )

      assert {:ok, %{value: "text"}} = Schema.validate(schema, %{"value" => "text"})
      assert {:ok, %{value: 5}} = Schema.validate(schema, %{"value" => 5})
      assert {:error, _} = Schema.validate(schema, %{"value" => [1, 2]})
    end

    test "validates enum with non-string values" do
      schema = Schema.enum([1, 2, 3])
      assert {:ok, 1} = Schema.validate(schema, 1)
      assert {:error, _} = Schema.validate(schema, 4)
    end

    test "validates free-form object" do
      schema = Schema.object([])
      assert {:ok, %{"anything" => "goes"}} = Schema.validate(schema, %{"anything" => "goes"})
      assert {:error, _} = Schema.validate(schema, "not a map")
    end

    test "validates free-form array" do
      schema = Schema.array([])
      assert {:ok, [1, "two", true]} = Schema.validate(schema, [1, "two", true])
      assert {:error, _} = Schema.validate(schema, "not a list")
    end

    test "validates mixed required and optional fields" do
      schema =
        Schema.object(
          %{
            name: Schema.string(),
            age: Schema.integer(),
            tags: Schema.array(Schema.string())
          },
          required: [:name]
        )

      assert {:ok, %{name: "Ada"}} = Schema.validate(schema, %{"name" => "Ada"})
      assert {:error, _} = Schema.validate(schema, %{"age" => 30})
    end
  end

  describe "format_errors/1" do
    test "formats a leaf error with path" do
      error = %Peri.Error{path: [:city], key: :city, message: "is required", errors: nil}
      result = Schema.format_errors([error])

      assert result == "- city: is required"
    end

    test "formats multiple errors" do
      errors = [
        %Peri.Error{path: [:city], key: :city, message: "is required", errors: nil},
        %Peri.Error{
          path: [:temperature],
          key: :temperature,
          message: "expected number",
          errors: nil
        }
      ]

      result = Schema.format_errors(errors)
      assert result =~ "city: is required"
      assert result =~ "temperature: expected number"
    end

    test "flattens nested errors" do
      nested = %Peri.Error{path: [:zip], key: :zip, message: "is required", errors: nil}

      parent = %Peri.Error{
        path: [:address],
        key: :address,
        message: nil,
        errors: [nested]
      }

      result = Schema.format_errors([parent])
      assert result =~ "zip: is required"
    end

    test "handles error with key only (no path)" do
      error = %Peri.Error{path: nil, key: :name, message: "is required", errors: nil}
      result = Schema.format_errors([error])

      assert result == "- name: is required"
    end
  end
end
