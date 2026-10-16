# Requires the optional llm_db package; the module guard (rather than a tag)
# is needed because the fixtures reference LLMDB.Model at file-eval time.
if Code.ensure_loaded?(LLMDB) do
  defmodule Omni.Sources.LLMDBTest do
    use ExUnit.Case, async: true

    import ExUnit.CaptureLog

    @moduletag :capture_log

    alias Omni.Provider
    alias Omni.Sources.LLMDB, as: Source

    # Merges are shallow: an override replaces its whole top-level key.
    defp llmdb_model(id, overrides \\ %{}) do
      %{
        id: id,
        provider: :test,
        name: id,
        modalities: %{input: [:text], output: [:text]},
        capabilities: %{chat: true, tools: %{enabled: true}},
        cost: %{input: 1.0, output: 2.0},
        limits: %{context: 100_000, output: 8192}
      }
      |> Map.merge(overrides)
      |> LLMDB.Model.new!()
    end

    describe "transform_provider/2 eligibility" do
      test "rejects non-chat, tool-less, retired, and non-text models" do
        models = [
          llmdb_model("kept"),
          llmdb_model("no-chat", %{capabilities: %{chat: false, tools: %{enabled: true}}}),
          llmdb_model("no-tools", %{capabilities: %{chat: true, tools: %{enabled: false}}}),
          llmdb_model("retired-flag", %{retired: true}),
          llmdb_model("retired-dated", %{lifecycle: %{status: "active", retires_at: "2020-01-01"}}),
          llmdb_model("no-text-in", %{modalities: %{input: [:image], output: [:text]}}),
          llmdb_model("no-text-out", %{modalities: %{input: [:text], output: [:image]}})
        ]

        loaded = Source.transform_provider(models, :test)

        assert Enum.map(loaded, & &1.id) == ["kept"]
      end

      test "keeps deprecated models — they remain callable" do
        models = [
          llmdb_model("deprecated-flag", %{deprecated: true}),
          llmdb_model("deprecated-dated", %{
            lifecycle: %{status: "active", deprecated_at: "2020-01-01"}
          })
        ]

        loaded = Source.transform_provider(models, :test)

        assert Enum.map(loaded, & &1.id) == ["deprecated-dated", "deprecated-flag"]
      end

      test "rejects models with missing modalities without crashing" do
        models = [llmdb_model("kept"), llmdb_model("no-modalities", %{modalities: nil})]

        loaded = Source.transform_provider(models, :test)

        assert Enum.map(loaded, & &1.id) == ["kept"]
      end
    end

    describe "transform_provider/2 reasoning" do
      # capabilities.reasoning.enabled is unreliable upstream — the transform
      # ORs it with signals from the extra passthrough.
      test "reads capabilities.reasoning.enabled" do
        models = [
          llmdb_model("thinker", %{
            capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}}
          }),
          llmdb_model("plain")
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1})

        assert by_id["thinker"].thinking
        refute by_id["plain"].thinking
      end

      test "extra signals override a false reasoning capability" do
        models = [
          llmdb_model("mandatory", %{extra: %{reasoning: %{mandatory: true}}}),
          llmdb_model("efforts", %{extra: %{reasoning: %{supported_efforts: ["low", "high"]}}}),
          llmdb_model("options", %{extra: %{reasoning_options: [%{effort: "low"}]}})
        ]

        loaded = Source.transform_provider(models, :test)

        assert Enum.all?(loaded, & &1.thinking)
      end

      test "reasoning_options become thinking data, with atom or string keys" do
        models = [
          llmdb_model("atoms", %{
            extra: %{reasoning_options: [%{type: "effort", values: ["low", "high"]}]}
          }),
          llmdb_model("strings", %{
            extra: %{"reasoning_options" => [%{"type" => "toggle"}]}
          }),
          llmdb_model("openrouter", %{
            extra: %{"reasoning" => %{"supported_efforts" => ["low", "medium"]}}
          })
        ]

        by_id = models |> Source.transform_provider(:test) |> Map.new(&{&1.id, &1})

        assert by_id["atoms"].thinking == %{efforts: ["low", "high"]}
        assert by_id["strings"].thinking == %{toggle: true}
        assert by_id["openrouter"].thinking == %{efforts: ["low", "medium"]}
      end

      test "empty extra lists do not count as reasoning support" do
        # regression guard: [] is truthy, so these checks must be non-empty
        # checks rather than truthiness
        models = [
          llmdb_model("empty-efforts", %{extra: %{reasoning: %{supported_efforts: []}}}),
          llmdb_model("empty-options", %{extra: %{reasoning_options: []}})
        ]

        loaded = Source.transform_provider(models, :test)

        refute Enum.any?(loaded, & &1.thinking)
      end
    end

    describe "transform_provider/2 dialect resolution" do
      test "the wire protocol resolves the dialect" do
        models = [
          llmdb_model("data-first", %{
            execution: %{text: %{supported: true, wire_protocol: "anthropic_messages"}}
          })
        ]

        [model] = Source.transform_provider(models, :test)

        assert model.dialects.text == Omni.Dialects.AnthropicMessages
      end

      test "npm metadata resolves models of multi-dialect providers" do
        models = [llmdb_model("claude-x", %{extra: %{provider: %{npm: "@ai-sdk/anthropic"}}})]

        [model] = Source.transform_provider(models, :test)

        assert model.dialects.text == Omni.Dialects.AnthropicMessages
      end

      test "npm metadata is read from string-keyed extra (llm_db 2026.7.2+)" do
        models = [
          llmdb_model("claude-x", %{extra: %{"provider" => %{"npm" => "@ai-sdk/anthropic"}}})
        ]

        [model] = Source.transform_provider(models, :test)

        assert model.dialects.text == Omni.Dialects.AnthropicMessages
      end

      test "the wire protocol beats npm" do
        models = [
          llmdb_model("gpt-x", %{
            extra: %{provider: %{npm: "@ai-sdk/openai"}},
            execution: %{text: %{supported: true, wire_protocol: "openai_chat"}}
          })
        ]

        [model] = Source.transform_provider(models, :test)

        assert model.dialects.text == Omni.Dialects.OpenAICompletions
      end

      test "wire protocols map to dialects, renaming the divergent ones" do
        wire = fn protocol ->
          %{execution: %{text: %{supported: true, wire_protocol: protocol}}}
        end

        models = [
          llmdb_model("chat", wire.("openai_chat")),
          llmdb_model("gemini", wire.("google_generate_content")),
          llmdb_model("responses", wire.("openai_responses"))
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1.dialects[:text]})

        assert by_id["chat"] == Omni.Dialects.OpenAICompletions
        assert by_id["gemini"] == Omni.Dialects.GoogleGemini
        assert by_id["responses"] == Omni.Dialects.OpenAIResponses
      end

      test "an unknown wire protocol falls through to npm" do
        models = [
          llmdb_model("realtime", %{
            extra: %{provider: %{npm: "@ai-sdk/anthropic"}},
            execution: %{text: %{supported: true, wire_protocol: "openai_realtime"}}
          })
        ]

        [model] = Source.transform_provider(models, :test)

        assert model.dialects.text == Omni.Dialects.AnthropicMessages
      end

      test "a model with no dialect signal is left for the provider to fill" do
        [model] = Source.transform_provider([llmdb_model("bare")], :test)

        assert model.dialects == %{}
      end

      test "skips with a warning when the model's npm maps to no dialect" do
        models = [
          llmdb_model("unmapped", %{extra: %{provider: %{npm: "@ai-sdk/mistral"}}}),
          llmdb_model("kept", %{extra: %{provider: %{npm: "@ai-sdk/openai"}}})
        ]

        {loaded, log} = with_log(fn -> Source.transform_provider(models, :test) end)

        assert Enum.map(loaded, & &1.id) == ["kept"]
        assert log =~ "skipping test:unmapped: npm package @ai-sdk/mistral maps to no dialect"
        assert log =~ "loaded 1 models, skipped 1"
      end

      test "skips with a warning when a model is served from another base URL" do
        models = [
          llmdb_model("elsewhere", %{base_url: "https://other.test/v1"}),
          llmdb_model("kept")
        ]

        {loaded, log} =
          with_log(fn -> Source.transform_provider(models, :test, "https://api.test/v1") end)

        assert Enum.map(loaded, & &1.id) == ["kept"]
        assert log =~ "served from https://other.test/v1"
      end
    end

    describe "transform_provider/2 field mapping" do
      test "maps costs, limits, and release date" do
        models = [
          llmdb_model("full", %{
            release_date: "2025-08-05",
            cost: %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
            limits: %{context: 200_000, output: 64_000}
          })
        ]

        [model] = Source.transform_provider(models, :test)

        assert %Omni.Model{
                 name: "full",
                 provider: nil,
                 release_date: ~D[2025-08-05],
                 input_cost: 3.0,
                 output_cost: 15.0,
                 cache_read_cost: 0.3,
                 cache_write_cost: 3.75,
                 context_size: 200_000,
                 max_output_tokens: 64_000
               } = model
      end

      test "clamps negative cost sentinels and defaults missing costs and limits" do
        models = [
          llmdb_model("router", %{cost: %{input: -1.0e6, output: -1.0e6}}),
          llmdb_model("bare", %{cost: nil, limits: nil})
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1})

        assert %Omni.Model{input_cost: 0, output_cost: 0} = by_id["router"]

        assert %Omni.Model{
                 input_cost: 0,
                 output_cost: 0,
                 cache_read_cost: 0,
                 cache_write_cost: 0,
                 context_size: 0,
                 max_output_tokens: 0
               } = by_id["bare"]
      end

      test "filters modalities to the supported set before atomizing" do
        models = [
          llmdb_model("multi", %{
            modalities: %{input: [:text, :image, :audio, :document], output: [:text, :audio]}
          })
        ]

        [model] = Source.transform_provider(models, :test)

        assert model.input_modalities == [:text, :image]
        assert model.output_modalities == [:text]
      end

      test "strips the provider prefix from names, falling back to the id" do
        models = [
          llmdb_model("claude-x", %{name: "Anthropic: Claude X"}),
          llmdb_model("nameless", %{name: nil})
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1.name})

        assert by_id["claude-x"] == "Claude X"
        assert by_id["nameless"] == "nameless"
      end

      test "skips a model whose data fails to build while siblings load" do
        models = [
          llmdb_model("kept"),
          llmdb_model("bad-date", %{release_date: "garbage"})
        ]

        {loaded, log} =
          with_log(fn -> Source.transform_provider(models, :test) end)

        assert Enum.map(loaded, & &1.id) == ["kept"]
        assert log =~ "skipping test:bad-date"
      end

      test "sorts models by id" do
        models = [llmdb_model("zeta"), llmdb_model("alpha"), llmdb_model("mid")]

        loaded = Source.transform_provider(models, :test)

        assert Enum.map(loaded, & &1.id) == ["alpha", "mid", "zeta"]
      end
    end

    describe "transform_provider/2 alias expansion" do
      test "expands one model per alias, sharing the canonical's data" do
        models = [
          llmdb_model("claude-x-20260101", %{name: "Claude X", aliases: ["claude-x"]})
        ]

        loaded = Source.transform_provider(models, :test)

        assert Enum.map(loaded, & &1.id) == ["claude-x", "claude-x-20260101"]
        assert Enum.map(loaded, & &1.name) == ["Claude X", "Claude X"]
      end

      test "a canonical record beats an alias with the same id" do
        models = [
          llmdb_model("claude-x", %{name: "Canonical"}),
          llmdb_model("claude-x-20260101", %{name: "Aliased", aliases: ["claude-x"]})
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1.name})

        assert map_size(by_id) == 2
        assert by_id["claude-x"] == "Canonical"
        assert by_id["claude-x-20260101"] == "Aliased"
      end

      test "the first alias wins when two models share one" do
        models = [
          llmdb_model("model-a", %{name: "A", aliases: ["shared"]}),
          llmdb_model("model-b", %{name: "B", aliases: ["shared"]})
        ]

        loaded = Source.transform_provider(models, :test)
        by_id = Map.new(loaded, &{&1.id, &1.name})

        assert map_size(by_id) == 3
        assert by_id["shared"] == "A"
      end
    end

    describe "fetch/2 against the llm_db catalog" do
      test "returns the provider record and its models" do
        assert {:ok, %Provider{} = provider, models} = Source.fetch(:anthropic, [])

        assert provider.id == :anthropic
        assert provider.api_key == {:system, "ANTHROPIC_API_KEY"}
        assert models != []
        assert Enum.all?(models, &(&1.provider == nil))
        assert Enum.all?(models, &(&1.dialects.text == Omni.Dialects.AnthropicMessages))
      end

      test "canonical ids are llm_db catalog ids verbatim" do
        assert {:ok, _, [_ | _]} = Source.fetch(:moonshotai, [])

        assert {:ok, _, [_ | _] = ollama} = Source.fetch(:ollama_cloud, [])

        # The catalog reports Ollama's OpenAI-compatible endpoint; the native
        # dialect preference is re-applied by OllamaCloud's models/2.
        assert Enum.all?(ollama, &(&1.dialects.text == Omni.Dialects.OpenAICompletions))
      end

      test "gives opencode a provider-level dialect for models with no signal" do
        assert {:ok, provider, [_ | _]} = Source.fetch(:opencode, [])

        assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      end

      test "returns :unknown_provider for a catalog id llm_db doesn't know" do
        assert {:error, :unknown_provider} = Source.fetch(:does_not_exist, [])
      end
    end
  end
end
