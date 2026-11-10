# Requires the optional llm_db package (see llmdb_test.exs for the guard
# rationale).
if Code.ensure_loaded?(LLMDB) do
  defmodule Omni.Sources.LLMDBGoldenTest do
    # Golden test over the llm_db catalog, mirroring the ModelsDev golden
    # test: the quality gate for the llm_db snapshot + transform combination.
    # A failure after a routine `mix deps.update llm_db` *is* the review step
    # — re-verify the loaded set, then refresh the version pin, counts, and
    # golden models below.
    #
    # async: false — assembles each built-in through the real load path, which
    # reads app config that other sync tests may set temporarily.
    use ExUnit.Case, async: false

    import ExUnit.CaptureLog

    alias Omni.Provider.Loader

    # Assembled without touching the store, so llm_db models never leak into
    # tests that read the boot-time catalog. Load warnings (models skipped for
    # having no dialect) are captured, not printed mid-run.
    setup_all do
      {models, _log} =
        with_log(fn ->
          Omni.Source.with_cache(fn ->
            Map.new(Omni.Provider.builtins(), fn id ->
              {_provider, models} = Loader.assemble(id, source: Omni.Sources.LLMDB)
              {id, models}
            end)
          end)
        end)

      %{models: models}
    end

    @known_dialects [
      Omni.Dialects.AnthropicMessages,
      Omni.Dialects.OpenAICompletions,
      Omni.Dialects.OpenAIResponses,
      Omni.Dialects.GoogleGenerateContent,
      Omni.Dialects.OllamaChat,
      Omni.Dialects.TypeSafeSystemOne,
      Omni.Dialects.OpenAIDecisions
    ]

    # Wide bands (roughly 0.5x–2.5x of llm_db 2026.6.4's counts): they catch
    # a provider's catalog emptying or exploding without churning on routine
    # dependency bumps.
    @expected_counts %{
      alibaba: 20..120,
      anthropic: 8..40,
      google: 5..28,
      groq: 3..20,
      mistral: 20..100,
      moonshotai: 4..25,
      nearai: 15..85,
      # local instance — models come from user config, never a catalog
      ollama: 0..0,
      ollama_cloud: 20..100,
      openai: 20..100,
      opencode: 35..180,
      openrouter: 120..640,
      togetherai: 14..70,
      # no models.dev entry — the module lists TypeSafe's documented models
      typesafe: 2..10,
      venice: 35..180,
      xai: 18..90,
      zai: 7..35
    }

    test "the goldens below were verified against this llm_db version" do
      # llm_db upgraded? Re-run the load, re-verify the golden expectations
      # in this file against the new catalog, then update this pin.
      assert to_string(Application.spec(:llm_db, :vsn)) == "2026.10.6"
    end

    test "every built-in provider loads a model set within the expected range", %{models: models} do
      for id <- Omni.Provider.builtins() do
        count = length(models[id])
        range = Map.fetch!(@expected_counts, id)

        assert count in range,
               "#{id}: expected #{inspect(range)} models from llm_db, got #{count}"
      end
    end

    test "every model satisfies the source contract", %{models: models} do
      supported_input = Omni.Model.supported_modalities(:input)
      supported_output = Omni.Model.supported_modalities(:output)

      for id <- Omni.Provider.builtins(), model <- models[id] do
        assert is_binary(model.id), "#{id}: model without a string id: #{inspect(model)}"
        assert model.provider.id == id, "#{id}:#{model.id}: provider not stamped"
        assert model.dialects != %{}, "#{id}:#{model.id}: no dialect"

        for {capability, dialect} <- model.dialects do
          assert dialect in @known_dialects, "#{id}:#{model.id}: bad dialect"
          assert Omni.Dialect.capability(dialect) == capability
        end

        assert Enum.all?(model.input_modalities, &(&1 in supported_input))
        assert Enum.all?(model.output_modalities, &(&1 in supported_output))

        for field <- [:input_cost, :output_cost, :cache_read_cost, :cache_write_cost] do
          assert Map.fetch!(model, field) >= 0, "#{id}:#{model.id}: negative #{field}"
        end

        assert model.context_size >= 0
        assert model.max_output_tokens >= 0
      end
    end

    test "model ids are unique per provider after alias expansion", %{models: models} do
      for id <- Omni.Provider.builtins() do
        ids = Enum.map(models[id], & &1.id)

        assert ids == Enum.uniq(ids), "#{id}: duplicate model ids after alias expansion"
      end
    end

    test "ollama cloud models carry the native dialect", %{models: models} do
      assert models[:ollama_cloud] != []
      assert Enum.all?(models[:ollama_cloud], &(&1.dialects.text == Omni.Dialects.OllamaChat))
    end

    test "venice models are enriched with the :pdf input modality", %{models: models} do
      assert models[:venice] != []
      assert Enum.all?(models[:venice], &(:pdf in &1.input_modalities))
    end

    test "golden models match the catalog exactly", %{models: models} do
      goldens = %{
        # a decision model with no modalities in llm_db
        {:typesafe, "jev-1.13.0"} => %Omni.Model{
          id: "jev-1.13.0",
          name: "Jev 1.13",
          dialects: %{decision: Omni.Dialects.TypeSafeSystemOne},
          release_date: nil,
          context_size: 0,
          max_output_tokens: 0,
          thinking: false,
          input_modalities: [:text],
          output_modalities: [:text],
          input_cost: 0.042,
          output_cost: 0.0,
          cache_read_cost: 0,
          cache_write_cost: 0
        },
        # text and evaluate entries in llm_db: both capabilities from the catalog
        {:openai, "gpt-6-luna"} => %Omni.Model{
          id: "gpt-6-luna",
          name: "GPT-6 Luna",
          dialects: %{
            text: Omni.Dialects.OpenAIResponses,
            decision: Omni.Dialects.OpenAIDecisions
          },
          release_date: ~D[2026-09-22],
          context_size: 1_050_000,
          max_output_tokens: 128_000,
          thinking: %{efforts: ["none", "low", "medium", "high", "xhigh", "max"]},
          input_modalities: [:text, :image, :pdf],
          output_modalities: [:text],
          input_cost: 0.1,
          output_cost: 0.5,
          cache_read_cost: 0.01,
          cache_write_cost: 0.125
        },
        # an alias-expanded entry: llm_db's canonical id is the dated snapshot
        {:anthropic, "claude-sonnet-4-5"} => %Omni.Model{
          id: "claude-sonnet-4-5",
          name: "Claude Sonnet 4.5",
          dialects: %{text: Omni.Dialects.AnthropicMessages},
          release_date: ~D[2025-09-29],
          context_size: 200_000,
          max_output_tokens: 64_000,
          thinking: %{budget: {1024, nil}},
          input_modalities: [:text, :image, :pdf],
          output_modalities: [:text],
          input_cost: 3.0,
          output_cost: 15.0,
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
end
