defmodule Omni.ModelTest do
  use ExUnit.Case, async: true

  alias Omni.Model

  describe "new/1" do
    test "creates model from keyword list with all fields" do
      model =
        Model.new(
          id: "claude-sonnet-4-20250514",
          name: "Claude Sonnet 4",
          provider: SomeProvider,
          dialect: SomeDialect,
          context_size: 200_000,
          max_output_tokens: 8192,
          reasoning: true,
          input_modalities: [:text, :image],
          output_modalities: [:text],
          input_cost: 3.0,
          output_cost: 15.0,
          cache_read_cost: 0.3,
          cache_write_cost: 3.75
        )

      assert model.id == "claude-sonnet-4-20250514"
      assert model.name == "Claude Sonnet 4"
      assert model.provider == SomeProvider
      assert model.dialect == SomeDialect
      assert model.context_size == 200_000
      assert model.max_output_tokens == 8192
      assert model.reasoning == true
      assert model.input_modalities == [:text, :image]
      assert model.output_modalities == [:text]
      assert model.input_cost == 3.0
      assert model.output_cost == 15.0
      assert model.cache_read_cost == 0.3
      assert model.cache_write_cost == 3.75
    end

    test "defaults numeric fields to zero" do
      model = Model.new(id: "test", name: "Test", provider: P, dialect: D)

      assert model.context_size == 0
      assert model.max_output_tokens == 0
      assert model.input_cost == 0
      assert model.output_cost == 0
      assert model.cache_read_cost == 0
      assert model.cache_write_cost == 0
    end

    test "defaults reasoning to false" do
      model = Model.new(id: "test", name: "Test", provider: P, dialect: D)
      assert model.reasoning == false
    end

    test "defaults modalities to [:text]" do
      model = Model.new(id: "test", name: "Test", provider: P, dialect: D)
      assert model.input_modalities == [:text]
      assert model.output_modalities == [:text]
    end

    test "raises on missing enforced keys" do
      assert_raise ArgumentError, fn ->
        Model.new(id: "test")
      end
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Model.new(id: "test", name: "Test", provider: P, dialect: D, bogus: true)
      end
    end
  end
end
