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

    test "never fills dialects from the provider" do
      provider = Fixtures.provider(dialect: Omni.Dialects.OpenAIResponses)

      model = Model.new(id: "test", name: "Test", provider: provider)

      assert model.dialects == %{}
    end

    test "keeps a given dialect" do
      provider = Fixtures.provider(dialect: Omni.Dialects.OpenAIResponses)

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

  describe "get/1" do
    setup do
      %{provider: Fixtures.load_provider(models: ["org/model:tag"])}
    end

    test "looks up a string or tuple reference", %{provider: id} do
      hyphenated = id |> Atom.to_string() |> String.replace("_", "-")

      for ref <- [
            {id, "org/model:tag"},
            "#{id}:org/model:tag",
            "#{id}/org/model:tag",
            "#{hyphenated}:org/model:tag"
          ] do
        assert {:ok, %Model{id: "org/model:tag", provider: %Provider{id: ^id}}} = Model.get(ref)
      end
    end

    test "returns the errors of parse_ref/1, then get/2", %{provider: id} do
      assert {:error, {:invalid_model_ref, "model"}} = Model.get("model")
      assert {:error, {:unknown_provider, "model_test_nope"}} = Model.get("model_test_nope:m")
      assert {:error, {:unknown_model, ^id, "other"}} = Model.get("#{id}:other")
      assert {:error, {:unknown_provider, :nonexistent}} = Model.get({:nonexistent, "m"})
    end
  end

  describe "parse_ref/1" do
    test "splits at the first colon or slash" do
      assert Model.parse_ref("anthropic:claude-haiku-5-5") ==
               {:ok, {:anthropic, "claude-haiku-5-5"}}

      assert Model.parse_ref("anthropic/claude-haiku-5-5") ==
               {:ok, {:anthropic, "claude-haiku-5-5"}}

      assert Model.parse_ref("openrouter:typesafe/jev-1.14") ==
               {:ok, {:openrouter, "typesafe/jev-1.14"}}

      assert Model.parse_ref("openrouter/typesafe/jev-1.14") ==
               {:ok, {:openrouter, "typesafe/jev-1.14"}}

      assert Model.parse_ref("ollama/qwen3:8b") == {:ok, {:ollama, "qwen3:8b"}}
      assert Model.parse_ref("ollama:qwen3:8b") == {:ok, {:ollama, "qwen3:8b"}}
      assert Model.parse_ref("openai:@cf/meta/llama@x") == {:ok, {:openai, "@cf/meta/llama@x"}}
    end

    test "reads the provider's catalog spelling" do
      assert Model.parse_ref("ollama-cloud:gemma4:31b") == {:ok, {:ollama_cloud, "gemma4:31b"}}
    end

    test "doesn't look the model up" do
      assert Model.parse_ref("anthropic:no-such-model") == {:ok, {:anthropic, "no-such-model"}}
    end

    test "a string without a provider and model id is invalid" do
      for ref <- ["claude-haiku-5-5", "anthropic:", ":claude-haiku-5-5", "/x", ""] do
        assert Model.parse_ref(ref) == {:error, {:invalid_model_ref, ref}}
      end
    end

    test "a provider that isn't loaded is unknown, as written" do
      assert Model.parse_ref("model-test-never-an-atom:m") ==
               {:error, {:unknown_provider, "model-test-never-an-atom"}}

      # The atom exists, but no provider with that id is loaded.
      _ = :model_test_unloaded

      assert Model.parse_ref("model_test_unloaded:m") ==
               {:error, {:unknown_provider, "model_test_unloaded"}}
    end
  end

  describe "put/1" do
    @text %{text: Omni.Dialects.OpenAICompletions}

    setup do
      %{provider: Fixtures.load_provider()}
    end

    test "registers a model retrievable via get/2", %{provider: id} do
      model = Model.new(id: "custom-1", name: "Custom 1", provider: id, dialects: @text)
      assert :ok = Model.put(model)
      assert {:ok, ^model} = Model.get(id, "custom-1")
    end

    test "merges with existing models without clobbering", %{provider: id} do
      model_a = Model.new(id: "model-a", name: "A", provider: id, dialects: @text)
      model_b = Model.new(id: "model-b", name: "B", provider: id, dialects: @text)

      Model.put(model_a)
      Model.put(model_b)

      assert {:ok, ^model_a} = Model.get(id, "model-a")
      assert {:ok, ^model_b} = Model.get(id, "model-b")
    end

    test "replaces a model with the same ID", %{provider: id} do
      original = Model.new(id: "model-x", name: "Original", provider: id, dialects: @text)

      updated =
        Model.new(
          id: "model-x",
          name: "Updated",
          provider: id,
          dialects: @text,
          context_size: 100_000
        )

      Model.put(original)
      Model.put(updated)

      assert {:ok, result} = Model.get(id, "model-x")
      assert result.name == "Updated"
      assert result.context_size == 100_000
    end

    test "appears in list/1 results", %{provider: id} do
      model = Model.new(id: "listed-model", name: "Listed", provider: id, dialects: @text)
      Model.put(model)

      assert {:ok, models} = Model.list(id)
      assert model in models
    end

    test "raises when the model has no dialects", %{provider: id} do
      assert_raise ArgumentError, ~r/has no dialects/, fn ->
        Model.put(Model.new(id: "bare", name: "Bare", provider: id))
      end
    end

    test "raises when the model's provider isn't loaded" do
      model =
        Model.new(
          id: "orphan",
          name: "Orphan",
          provider: Fixtures.provider(id: :not_loaded),
          dialects: @text
        )

      assert_raise ArgumentError, ~r/not loaded/, fn -> Model.put(model) end
    end

    test "raises when the model has no provider" do
      assert_raise ArgumentError, ~r/no provider/, fn ->
        Model.put(Model.new(id: "bare", name: "Bare"))
      end
    end
  end

  describe "dialect/2, capability?/2 and capabilities/1" do
    test "return the dialect a model names for a capability" do
      model =
        Fixtures.model(id: "d", capability: :decision, dialect: Omni.Dialects.TypeSafeSystemOne)

      assert Model.dialect(model, :decision) == {:ok, Omni.Dialects.TypeSafeSystemOne}
      assert Model.dialect(model, :text) == {:error, {:unsupported_capability, :text}}
      assert Model.capability?(model, :decision)
      refute Model.capability?(model, :text)
      assert Model.capabilities(model) == [:decision]
    end

    test "a model may serve both capabilities" do
      model =
        Model.new(
          id: "both",
          name: "both",
          dialects: %{
            text: Omni.Dialects.OpenAIResponses,
            decision: Omni.Dialects.OpenAIDecisions
          }
        )

      assert Model.capability?(model, :text)
      assert Model.capability?(model, :decision)
      assert Model.capabilities(model) == [:decision, :text]
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

  describe "to_ref/2" do
    test "writes a model or tuple in each form" do
      model = Model.new(id: "org/m:tag", name: "M", provider: Fixtures.provider(id: :venice))

      for input <- [model, {:venice, "org/m:tag"}] do
        assert Model.to_ref(input, :tuple) == {:venice, "org/m:tag"}
        assert Model.to_ref(input, :colon) == "venice:org/m:tag"
        assert Model.to_ref(input, :slash) == "venice/org/m:tag"
      end
    end

    test "round-trips through parse_ref/1" do
      ref = {:openrouter, "@cf/org/m:tag@x"}

      for format <- [:colon, :slash] do
        assert ref |> Model.to_ref(format) |> Model.parse_ref() == {:ok, ref}
      end
    end
  end

  describe "String.Chars" do
    test "interpolates as a colon reference" do
      model = Model.new(id: "org/m", name: "M", provider: Fixtures.provider(id: :venice))
      assert "#{model}" == "venice:org/m"
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
