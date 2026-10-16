defmodule Omni.ModelTest do
  use ExUnit.Case, async: true

  alias Omni.{Model, Provider}
  alias Omni.Test.Fixtures

  describe "new/1" do
    test "creates model from keyword list with all fields" do
      model =
        Model.new(
          id: "claude-sonnet-4-20250514",
          name: "Claude Sonnet 4",
          provider: Fixtures.provider(),
          dialects: %{text: Omni.Dialects.AnthropicMessages},
          context_size: 200_000,
          max_output_tokens: 8192,
          thinking: true,
          input_modalities: [:text, :image],
          output_modalities: [:text],
          input_cost: 3.0,
          output_cost: 15.0,
          cache_read_cost: 0.3,
          cache_write_cost: 3.75
        )

      assert model.id == "claude-sonnet-4-20250514"
      assert model.name == "Claude Sonnet 4"
      assert model.provider == Fixtures.provider()
      assert model.dialects == %{text: Omni.Dialects.AnthropicMessages}
      assert model.context_size == 200_000
      assert model.max_output_tokens == 8192
      assert model.thinking == true
      assert model.input_modalities == [:text, :image]
      assert model.output_modalities == [:text]
      assert model.input_cost == 3.0
      assert model.output_cost == 15.0
      assert model.cache_read_cost == 0.3
      assert model.cache_write_cost == 3.75
    end

    test "defaults numeric fields to zero" do
      model = Model.new(id: "test", name: "Test")

      assert model.context_size == 0
      assert model.max_output_tokens == 0
      assert model.input_cost == 0
      assert model.output_cost == 0
      assert model.cache_read_cost == 0
      assert model.cache_write_cost == 0
    end

    test "defaults thinking to false" do
      model = Model.new(id: "test", name: "Test")
      assert model.thinking == false
    end

    test "normalizes a thinking map or keyword list" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          thinking: [efforts: [:low, "high"], toggle: true, budget: {1024, nil}]
        )

      assert model.thinking == %{efforts: ["low", "high"], toggle: true, budget: {1024, nil}}
    end

    test "an empty thinking map means true" do
      assert Model.new(id: "a", name: "A", thinking: %{}).thinking == true

      assert Model.new(id: "b", name: "B", thinking: [efforts: [], toggle: false]).thinking ==
               true
    end

    test "raises a migration message for :reasoning" do
      assert_raise ArgumentError, ~r/renamed to :thinking/, fn ->
        Model.new(id: "test", name: "Test", reasoning: true)
      end
    end

    test "defaults modalities to [:text]" do
      model = Model.new(id: "test", name: "Test")
      assert model.input_modalities == [:text]
      assert model.output_modalities == [:text]
    end

    test "raises on missing enforced keys" do
      assert_raise ArgumentError, fn ->
        Model.new(id: "test")
      end
    end

    test "leaves provider and dialects empty when not given" do
      model = Model.new(id: "test", name: "Test")

      assert model.provider == nil
      assert model.dialects == %{}
    end

    test "fills missing dialects from the provider's first dialect" do
      provider =
        Fixtures.provider(
          dialects: %{text: [Omni.Dialects.OpenAIResponses, Omni.Dialects.OpenAICompletions]}
        )

      model = Model.new(id: "test", name: "Test", provider: provider)

      assert model.dialects == %{text: Omni.Dialects.OpenAIResponses}
    end

    test "keeps a given dialect over the provider's" do
      provider = Fixtures.provider(dialects: %{text: [Omni.Dialects.OpenAIResponses]})

      model =
        Model.new(
          id: "test",
          name: "Test",
          provider: provider,
          dialects: %{text: Omni.Dialects.OpenAICompletions}
        )

      assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
    end

    test "resolves a loaded provider id to its struct" do
      {:ok, anthropic} = Provider.get(:anthropic)
      model = Model.new(id: "test", name: "Test", provider: :anthropic)

      assert model.provider == anthropic
      assert model.dialects == %{text: Omni.Dialects.AnthropicMessages}
    end

    test "raises for a provider id that isn't loaded" do
      assert_raise ArgumentError, ~r/not loaded/, fn ->
        Model.new(id: "test", name: "Test", provider: :nonexistent)
      end
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Model.new(id: "test", name: "Test", bogus: true)
      end
    end

    test "filters unsupported input modalities" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          input_modalities: [:text, :image, :audio, :video]
        )

      assert model.input_modalities == [:text, :image]
    end

    test "filters unsupported output modalities" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          output_modalities: [:text, :audio]
        )

      assert model.output_modalities == [:text]
    end

    test "defaults to [:text] when all modalities are unsupported" do
      model =
        Model.new(
          id: "test",
          name: "Test",
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
      {:ok, [%Model{id: model_id} | _]} = Model.list(:anthropic)

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

  describe "put/1" do
    setup do
      %{provider: Fixtures.load_provider()}
    end

    test "registers a model retrievable via get/2", %{provider: id} do
      model = Model.new(id: "custom-1", name: "Custom 1", provider: id)
      assert :ok = Model.put(model)
      assert {:ok, ^model} = Model.get(id, "custom-1")
    end

    test "merges with existing models without clobbering", %{provider: id} do
      model_a = Model.new(id: "model-a", name: "A", provider: id)
      model_b = Model.new(id: "model-b", name: "B", provider: id)

      Model.put(model_a)
      Model.put(model_b)

      assert {:ok, ^model_a} = Model.get(id, "model-a")
      assert {:ok, ^model_b} = Model.get(id, "model-b")
    end

    test "replaces a model with the same ID", %{provider: id} do
      original = Model.new(id: "model-x", name: "Original", provider: id)
      updated = Model.new(id: "model-x", name: "Updated", provider: id, context_size: 100_000)

      Model.put(original)
      Model.put(updated)

      assert {:ok, result} = Model.get(id, "model-x")
      assert result.name == "Updated"
      assert result.context_size == 100_000
    end

    test "appears in list/1 results", %{provider: id} do
      model = Model.new(id: "listed-model", name: "Listed", provider: id)
      Model.put(model)

      assert {:ok, models} = Model.list(id)
      assert model in models
    end

    test "raises when the model's provider isn't loaded" do
      model =
        Model.new(id: "orphan", name: "Orphan", provider: Fixtures.provider(id: :not_loaded))

      assert_raise ArgumentError, ~r/not loaded/, fn -> Model.put(model) end
    end

    test "raises when the model has no provider" do
      assert_raise ArgumentError, ~r/no provider/, fn ->
        Model.put(Model.new(id: "bare", name: "Bare"))
      end
    end
  end

  describe "to_ref/1" do
    test "returns {provider_id, model_id} for a loaded model" do
      {:ok, [model | _]} = Model.list(:anthropic)
      {provider_id, model_id} = Model.to_ref(model)
      assert provider_id == :anthropic
      assert model_id == model.id
    end

    test "reads the id from the embedded provider" do
      model = Model.new(id: "test", name: "Test", provider: Fixtures.provider(id: :venice))

      assert Model.to_ref(model) == {:venice, "test"}
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
