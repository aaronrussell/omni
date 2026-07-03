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
    # async: false — sets the global source config and calls each provider's
    # models/0 (the real boot path).
    use ExUnit.Case, async: false

    setup_all do
      Application.put_env(:omni, :providers, source: :llm_db)
      on_exit(fn -> Application.delete_env(:omni, :providers) end)

      models =
        Omni.Source.with_cache(fn ->
          Map.new(Omni.Provider.builtin_providers(), fn {id, mod} -> {id, mod.models()} end)
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

    # Wide bands (roughly 0.5x–2.5x of llm_db 2026.6.4's counts): they catch
    # a provider's catalog emptying or exploding without churning on routine
    # dependency bumps.
    @expected_counts %{
      alibaba: 20..120,
      anthropic: 8..40,
      google: 5..28,
      groq: 3..20,
      moonshot: 4..25,
      nearai: 15..85,
      ollama: 20..100,
      openai: 20..100,
      opencode: 35..180,
      openrouter: 120..640,
      venice: 35..180,
      zai: 7..35
    }

    test "the goldens below were verified against this llm_db version" do
      # llm_db upgraded? Re-run the load, re-verify the golden expectations
      # in this file against the new catalog, then update this pin.
      assert to_string(Application.spec(:llm_db, :vsn)) == "2026.6.4"
    end

    test "every built-in provider loads a model set within the expected range", %{models: models} do
      for {id, _mod} <- Omni.Provider.builtin_providers() do
        count = length(models[id])
        range = Map.fetch!(@expected_counts, id)

        assert count in range,
               "#{id}: expected #{inspect(range)} models from llm_db, got #{count}"
      end
    end

    test "every model satisfies the source contract", %{models: models} do
      supported_input = Omni.Model.supported_modalities(:input)
      supported_output = Omni.Model.supported_modalities(:output)

      for {id, mod} <- Omni.Provider.builtin_providers(), model <- models[id] do
        assert is_binary(model.id), "#{id}: model without a string id: #{inspect(model)}"
        assert model.provider == mod, "#{id}:#{model.id}: provider not stamped"
        assert model.dialect in @known_dialects, "#{id}:#{model.id}: bad dialect"
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
      for {id, _mod} <- Omni.Provider.builtin_providers() do
        ids = Enum.map(models[id], & &1.id)

        assert ids == Enum.uniq(ids), "#{id}: duplicate model ids after alias expansion"
      end
    end

    test "ollama models carry the native dialect", %{models: models} do
      assert models[:ollama] != []
      assert Enum.all?(models[:ollama], &(&1.dialect == Omni.Dialects.OllamaChat))
    end

    test "venice models are enriched with the :pdf input modality", %{models: models} do
      assert models[:venice] != []
      assert Enum.all?(models[:venice], &(:pdf in &1.input_modalities))
    end

    test "golden models match the catalog exactly", %{models: models} do
      goldens = %{
        # an alias-expanded entry: llm_db's canonical id is the dated snapshot
        {:anthropic, "claude-sonnet-4-5"} => %Omni.Model{
          id: "claude-sonnet-4-5",
          name: "Claude Sonnet 4.5",
          provider: Omni.Providers.Anthropic,
          dialect: Omni.Dialects.AnthropicMessages,
          release_date: ~D[2025-09-29],
          context_size: 1_000_000,
          max_output_tokens: 64_000,
          reasoning: true,
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
          provider: Omni.Providers.OpenAI,
          dialect: Omni.Dialects.OpenAIResponses,
          release_date: ~D[2025-08-07],
          context_size: 400_000,
          max_output_tokens: 128_000,
          reasoning: true,
          input_modalities: [:text, :image],
          output_modalities: [:text],
          input_cost: 1.25,
          output_cost: 10,
          cache_read_cost: 0.125,
          cache_write_cost: 0
        }
      }

      for {{provider_id, model_id}, expected} <- goldens do
        actual = Enum.find(models[provider_id], &(&1.id == model_id))

        assert actual == expected,
               "golden model #{provider_id} #{model_id} drifted:\n" <>
                 "expected: #{inspect(expected)}\n" <>
                 "actual:   #{inspect(actual)}"
      end
    end
  end
end
