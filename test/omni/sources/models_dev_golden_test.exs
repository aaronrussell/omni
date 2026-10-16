defmodule Omni.Sources.ModelsDevGoldenTest do
  # Golden test over the committed models.dev snapshot.
  #
  # With verbatim snapshots nobody reviews transformed model data by hand, so
  # this test is the quality gate for the snapshot + transform combination:
  # it runs offline on every commit, and updating the expectations below when
  # `mix omni.snapshot` refreshes the snapshot *is* the human review step.
  #
  # async: false — assembles each built-in through the real load path, which
  # reads app config that other sync tests may set temporarily.
  use ExUnit.Case, async: false

  alias Omni.Provider.Loader

  # One cache pass for the whole suite: the snapshot is decoded once instead
  # of once per provider. Assembled without touching the store.
  setup_all do
    models =
      Omni.Source.with_cache(fn ->
        Map.new(Omni.Provider.builtins(), fn id ->
          {_provider, models} = Loader.assemble(id)
          {id, models}
        end)
      end)

    %{models: models}
  end

  @known_dialects [
    Omni.Dialects.AnthropicMessages,
    Omni.Dialects.OpenAICompletions,
    Omni.Dialects.OpenAIResponses,
    Omni.Dialects.GoogleGemini,
    Omni.Dialects.OllamaChat
  ]

  # Wide bands (roughly 0.5x–2.5x of the current snapshot's counts): they
  # catch a provider's catalog emptying or exploding without churning on
  # routine snapshot refreshes.
  @expected_counts %{
    alibaba: 20..120,
    anthropic: 9..45,
    google: 6..30,
    groq: 3..20,
    moonshotai: 4..25,
    nearai: 15..85,
    # local instance — models come from user config, never a catalog
    ollama: 0..0,
    ollama_cloud: 15..80,
    openai: 20..100,
    opencode: 25..125,
    openrouter: 120..640,
    venice: 35..180,
    zai: 7..35
  }

  test "every built-in provider loads a model set within the expected range", %{models: models} do
    for id <- Omni.Provider.builtins() do
      count = length(models[id])
      range = Map.fetch!(@expected_counts, id)

      assert count in range,
             "#{id}: expected #{inspect(range)} models from the snapshot, got #{count}"
    end
  end

  test "every model satisfies the source contract", %{models: models} do
    supported_input = Omni.Model.supported_modalities(:input)
    supported_output = Omni.Model.supported_modalities(:output)

    for id <- Omni.Provider.builtins(), model <- models[id] do
      assert is_binary(model.id), "#{id}: model without a string id: #{inspect(model)}"
      assert model.provider.id == id, "#{id}:#{model.id}: provider not stamped"
      assert model.dialects.text in @known_dialects, "#{id}:#{model.id}: bad dialect"
      assert Enum.all?(model.input_modalities, &(&1 in supported_input))
      assert Enum.all?(model.output_modalities, &(&1 in supported_output))

      for field <- [:input_cost, :output_cost, :cache_read_cost, :cache_write_cost] do
        assert Map.fetch!(model, field) >= 0, "#{id}:#{model.id}: negative #{field}"
      end

      assert model.context_size >= 0
      assert model.max_output_tokens >= 0
    end
  end

  test "ollama cloud models re-apply the native dialect over the catalog's", %{models: models} do
    assert models[:ollama_cloud] != []
    assert Enum.all?(models[:ollama_cloud], &(&1.dialects.text == Omni.Dialects.OllamaChat))
  end

  test "venice models are enriched with the :pdf input modality", %{models: models} do
    assert models[:venice] != []
    assert Enum.all?(models[:venice], &(:pdf in &1.input_modalities))
  end

  test "golden models match the snapshot exactly", %{models: models} do
    goldens = %{
      {:anthropic, "claude-sonnet-4-5"} => %Omni.Model{
        id: "claude-sonnet-4-5",
        name: "Claude Sonnet 4.5 (latest)",
        dialects: %{text: Omni.Dialects.AnthropicMessages},
        release_date: ~D[2025-09-29],
        context_size: 200_000,
        max_output_tokens: 64_000,
        thinking: %{budget: {1024, nil}},
        input_modalities: [:text, :image, :pdf],
        output_modalities: [:text],
        input_cost: 3,
        output_cost: 15,
        cache_read_cost: 0.3,
        cache_write_cost: 3.75
      },
      {:openai, "gpt-5"} => %Omni.Model{
        id: "gpt-5",
        name: "GPT-5",
        dialects: %{text: Omni.Dialects.OpenAIResponses},
        release_date: ~D[2025-08-07],
        context_size: 400_000,
        max_output_tokens: 128_000,
        thinking: %{efforts: ["minimal", "low", "medium", "high"]},
        input_modalities: [:text, :image],
        output_modalities: [:text],
        input_cost: 1.25,
        output_cost: 10,
        cache_read_cost: 0.125,
        cache_write_cost: 0
      },
      {:google, "gemini-2.5-pro"} => %Omni.Model{
        id: "gemini-2.5-pro",
        name: "Gemini 2.5 Pro",
        dialects: %{text: Omni.Dialects.GoogleGemini},
        release_date: ~D[2025-06-17],
        context_size: 1_048_576,
        max_output_tokens: 65_536,
        thinking: %{budget: {128, 32_768}},
        input_modalities: [:text, :image, :pdf],
        output_modalities: [:text],
        input_cost: 1.25,
        output_cost: 10,
        cache_read_cost: 0.125,
        cache_write_cost: 0
      },
      {:openrouter, "openai/gpt-4o"} => %Omni.Model{
        id: "openai/gpt-4o",
        name: "GPT-4o",
        dialects: %{text: Omni.Dialects.OpenAICompletions},
        release_date: ~D[2024-05-13],
        context_size: 128_000,
        max_output_tokens: 16_384,
        thinking: false,
        input_modalities: [:text, :image, :pdf],
        output_modalities: [:text],
        input_cost: 2.5,
        output_cost: 10,
        cache_read_cost: 1.25,
        cache_write_cost: 0
      }
    }

    for {{provider_id, model_id}, expected} <- goldens do
      found = Enum.find(models[provider_id], &(&1.id == model_id))
      assert found.provider.id == provider_id
      actual = %{found | provider: nil}

      assert actual == expected,
             "golden model #{provider_id} #{model_id} drifted:\n" <>
               "expected: #{inspect(expected)}\n" <>
               "actual:   #{inspect(actual)}"
    end
  end
end
