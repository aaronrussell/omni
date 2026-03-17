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

    test "filters unsupported input modalities" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          provider: P,
          dialect: D,
          input_modalities: [:text, :image, :audio, :video]
        )

      assert model.input_modalities == [:text, :image]
    end

    test "filters unsupported output modalities" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          provider: P,
          dialect: D,
          output_modalities: [:text, :audio]
        )

      assert model.output_modalities == [:text]
    end

    test "defaults to [:text] when all modalities are unsupported" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          provider: P,
          dialect: D,
          input_modalities: [:audio, :video]
        )

      assert model.input_modalities == [:text]
    end
  end

  describe "list/1" do
    test "returns {:ok, list} of models for a loaded provider" do
      assert {:ok, models} = Model.list(:anthropic)
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{}, &1))
    end

    test "returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Model.list(:nonexistent)
    end
  end

  describe "get/2" do
    test "returns {:ok, model} for a loaded model" do
      # Application loads anthropic at startup
      [model_id | _] = :persistent_term.get({Omni, :anthropic}) |> Map.keys()

      assert {:ok, %Model{id: ^model_id}} = Model.get(:anthropic, model_id)
    end

    test "returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Model.get(:nonexistent, "any-model")
    end

    test "returns error for unknown model ID" do
      assert {:error, {:unknown_model, :anthropic, "no-such-model"}} =
               Model.get(:anthropic, "no-such-model")
    end
  end

  describe "put/2" do
    setup do
      provider_id = :"test_put_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :persistent_term.erase({Omni, provider_id})
      end)

      %{provider_id: provider_id}
    end

    test "registers a model retrievable via get/2", %{provider_id: provider_id} do
      model = Model.new(id: "custom-1", name: "Custom 1", provider: P, dialect: D)
      assert :ok = Model.put(provider_id, model)
      assert {:ok, ^model} = Model.get(provider_id, "custom-1")
    end

    test "merges with existing models without clobbering", %{provider_id: provider_id} do
      model_a = Model.new(id: "model-a", name: "A", provider: P, dialect: D)
      model_b = Model.new(id: "model-b", name: "B", provider: P, dialect: D)

      Model.put(provider_id, model_a)
      Model.put(provider_id, model_b)

      assert {:ok, ^model_a} = Model.get(provider_id, "model-a")
      assert {:ok, ^model_b} = Model.get(provider_id, "model-b")
    end

    test "replaces a model with the same ID", %{provider_id: provider_id} do
      original = Model.new(id: "model-x", name: "Original", provider: P, dialect: D)

      updated =
        Model.new(id: "model-x", name: "Updated", provider: P, dialect: D, context_size: 100_000)

      Model.put(provider_id, original)
      Model.put(provider_id, updated)

      assert {:ok, result} = Model.get(provider_id, "model-x")
      assert result.name == "Updated"
      assert result.context_size == 100_000
    end

    test "appears in list/1 results", %{provider_id: provider_id} do
      model = Model.new(id: "listed-model", name: "Listed", provider: P, dialect: D)
      Model.put(provider_id, model)

      assert {:ok, models} = Model.list(provider_id)
      assert model in models
    end
  end

  describe "to_ref/1" do
    test "returns {provider_id, model_id} for a loaded model" do
      {:ok, [model | _]} = Model.list(:anthropic)
      {provider_id, model_id} = Model.to_ref(model)
      assert provider_id == :anthropic
      assert model_id == model.id
    end

    test "raises for an unloaded provider module" do
      model = Model.new(id: "test", name: "Test", provider: UnloadedProvider, dialect: D)

      assert_raise ArgumentError, ~r/UnloadedProvider is not loaded/, fn ->
        Model.to_ref(model)
      end
    end
  end

  describe "supported_modalities/1" do
    test "returns the supported input modalities" do
      assert Model.supported_modalities(:input) == [:text, :image, :pdf]
    end

    test "returns the supported output modalities" do
      assert Model.supported_modalities(:output) == [:text]
    end
  end
end
