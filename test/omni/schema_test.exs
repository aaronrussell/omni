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
      assert result.min_length == 1
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
    test "returns string type with enum constraint" do
      result = Schema.enum(["red", "green", "blue"])
      assert result == %{type: "string", enum: ["red", "green", "blue"]}
    end

    test "merges opts" do
      result = Schema.enum(["a", "b"], description: "Pick one")
      assert result.description == "Pick one"
      assert result.enum == ["a", "b"]
    end
  end

  describe "array/2" do
    test "nests the items schema" do
      result = Schema.array(Schema.string())
      assert result == %{type: "array", items: %{type: "string"}}
    end

    test "merges opts" do
      result = Schema.array(Schema.integer(), min_items: 1)
      assert result.type == "array"
      assert result.items == %{type: "integer"}
      assert result.min_items == 1
    end
  end

  describe "object/2" do
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

    test "composes nested schemas" do
      result =
        Schema.object(%{
          tags: Schema.array(Schema.string()),
          status: Schema.enum(["active", "inactive"])
        })

      assert result.properties.tags == %{type: "array", items: %{type: "string"}}
      assert result.properties.status == %{type: "string", enum: ["active", "inactive"]}
    end
  end

  describe "to_peri/1" do
    test "converts string type" do
      assert Schema.to_peri(Schema.string()) == :string
    end

    test "converts integer type" do
      assert Schema.to_peri(Schema.integer()) == :integer
    end

    test "converts number type to either integer or float" do
      assert Schema.to_peri(Schema.number()) == {:either, {:integer, :float}}
    end

    test "converts boolean type" do
      assert Schema.to_peri(Schema.boolean()) == :boolean
    end

    test "converts enum to Peri enum" do
      assert Schema.to_peri(Schema.enum(["a", "b"])) == {:enum, ["a", "b"]}
    end

    test "converts array to Peri list" do
      assert Schema.to_peri(Schema.array(Schema.string())) == {:list, :string}
    end

    test "converts object with atom keys" do
      peri = Schema.to_peri(Schema.object(%{name: Schema.string()}))
      assert peri == %{name: :string}
    end

    test "converts object with string keys" do
      peri = Schema.to_peri(Schema.object(%{"name" => Schema.string()}))
      assert peri == %{"name" => :string}
    end

    test "marks required fields" do
      peri = Schema.to_peri(Schema.object(%{city: Schema.string()}, required: [:city]))
      assert peri == %{city: {:required, :string}}
    end

    test "handles nested objects" do
      schema =
        Schema.object(%{
          address: Schema.object(%{zip: Schema.string()}, required: [:zip])
        })

      peri = Schema.to_peri(schema)
      assert peri == %{address: %{zip: {:required, :string}}}
    end

    test "handles mixed required and optional fields" do
      schema =
        Schema.object(
          %{
            name: Schema.string(),
            age: Schema.integer(),
            tags: Schema.array(Schema.string())
          },
          required: [:name]
        )

      peri = Schema.to_peri(schema)
      assert peri == %{name: {:required, :string}, age: :integer, tags: {:list, :string}}
    end
  end
end
