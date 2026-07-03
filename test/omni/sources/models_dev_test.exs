defmodule Omni.Sources.ModelsDevTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Omni.Sources.ModelsDev

  defmodule CompletionsProvider do
    use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

    @impl true
    def config, do: %{base_url: "https://api.test.com", api_key: nil}
  end

  defmodule GatewayProvider do
    use Omni.Provider

    @impl true
    def config, do: %{base_url: "https://api.test.com", api_key: nil}
  end

  defp model_entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "tool_call" => true,
        "modalities" => %{"input" => ["text"], "output" => ["text"]},
        "cost" => %{"input" => 1.0, "output" => 2.0},
        "limit" => %{"context" => 100_000, "output" => 8192}
      },
      overrides
    )
  end

  defp provider_data(models, overrides \\ %{}) do
    Map.merge(
      %{"npm" => "@ai-sdk/openai-compatible", "models" => models},
      overrides
    )
  end

  describe "transform_provider/3 eligibility" do
    test "rejects deprecated models, missing tool use, and non-text modalities" do
      data =
        provider_data([
          model_entry("kept"),
          model_entry("deprecated", %{"status" => "deprecated"}),
          model_entry("no-tools", %{"tool_call" => false}),
          model_entry("tools-missing", %{}) |> Map.delete("tool_call"),
          model_entry("no-text-in", %{
            "modalities" => %{"input" => ["image"], "output" => ["text"]}
          }),
          model_entry("no-text-out", %{
            "modalities" => %{"input" => ["text"], "output" => ["image"]}
          })
        ])

      models = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert Enum.map(models, & &1.id) == ["kept"]
    end

    test "rejects models with missing or malformed modalities without crashing" do
      data =
        provider_data([
          model_entry("kept"),
          model_entry("no-modalities", %{}) |> Map.delete("modalities"),
          model_entry("weird-modalities", %{"modalities" => "text"})
        ])

      models = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert Enum.map(models, & &1.id) == ["kept"]
    end
  end

  describe "transform_provider/3 dialect resolution" do
    test "derives the dialect from the provider-level npm package" do
      data =
        provider_data([model_entry("claude-x")], %{"npm" => "@ai-sdk/anthropic"})

      [model] = ModelsDev.transform_provider(data, GatewayProvider, "test")

      assert model.dialect == Omni.Dialects.AnthropicMessages
    end

    test "per-model npm overrides the provider-level npm" do
      data =
        provider_data(
          [
            model_entry("gpt-x", %{"provider" => %{"npm" => "@ai-sdk/openai"}}),
            model_entry("other")
          ],
          %{"npm" => "@ai-sdk/anthropic"}
        )

      models = ModelsDev.transform_provider(data, GatewayProvider, "test")
      by_id = Map.new(models, &{&1.id, &1})

      assert by_id["gpt-x"].dialect == Omni.Dialects.OpenAIResponses
      assert by_id["other"].dialect == Omni.Dialects.AnthropicMessages
    end

    test "unmapped npm falls back to the module's declared dialect" do
      data = provider_data([model_entry("local")], %{"npm" => "some-unknown-sdk"})

      [model] = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert model.dialect == Omni.Dialects.OpenAICompletions
    end

    test "skips with a warning when no dialect resolves" do
      data =
        provider_data(
          [
            model_entry("no-dialect"),
            model_entry("kept", %{"provider" => %{"npm" => "@ai-sdk/openai"}})
          ],
          %{"npm" => "some-unknown-sdk"}
        )

      {models, log} =
        with_log(fn -> ModelsDev.transform_provider(data, GatewayProvider, "test") end)

      assert Enum.map(models, & &1.id) == ["kept"]
      assert log =~ "skipping test:no-dialect"
      assert log =~ "loaded 1 models, skipped 1"
    end
  end

  describe "transform_provider/3 field mapping" do
    test "maps costs, limits, reasoning, and release date" do
      data =
        provider_data([
          model_entry("full", %{
            "reasoning" => true,
            "release_date" => "2025-08-05",
            "cost" => %{
              "input" => 3.0,
              "output" => 15.0,
              "cache_read" => 0.3,
              "cache_write" => 3.75
            },
            "limit" => %{"context" => 200_000, "output" => 64_000}
          })
        ])

      [model] = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert %Omni.Model{
               name: "full",
               provider: CompletionsProvider,
               reasoning: true,
               release_date: ~D[2025-08-05],
               input_cost: 3.0,
               output_cost: 15.0,
               cache_read_cost: 0.3,
               cache_write_cost: 3.75,
               context_size: 200_000,
               max_output_tokens: 64_000
             } = model
    end

    test "defaults missing costs and limits to zero" do
      data =
        provider_data([
          model_entry("bare") |> Map.drop(["cost", "limit"])
        ])

      [model] = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert %Omni.Model{
               input_cost: 0,
               output_cost: 0,
               cache_read_cost: 0,
               cache_write_cost: 0,
               context_size: 0,
               max_output_tokens: 0,
               reasoning: false,
               release_date: nil
             } = model
    end

    test "filters modalities to the supported set before atomizing" do
      data =
        provider_data([
          model_entry("multi", %{
            "modalities" => %{
              "input" => ["text", "image", "video", "audio"],
              "output" => ["text", "audio"]
            }
          })
        ])

      [model] = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert model.input_modalities == [:text, :image]
      assert model.output_modalities == [:text]
    end

    test "skips a model whose data fails to build while siblings load" do
      data =
        provider_data([
          model_entry("kept"),
          model_entry("bad-date", %{"release_date" => "garbage"})
        ])

      {models, log} =
        with_log(fn -> ModelsDev.transform_provider(data, CompletionsProvider, "test") end)

      assert Enum.map(models, & &1.id) == ["kept"]
      assert log =~ "skipping test:bad-date"
    end

    test "sorts models by id" do
      data = provider_data([model_entry("zeta"), model_entry("alpha"), model_entry("mid")])

      models = ModelsDev.transform_provider(data, CompletionsProvider, "test")

      assert Enum.map(models, & &1.id) == ["alpha", "mid", "zeta"]
    end
  end

  describe "fetch/2 against the bundled snapshot" do
    test "loads models for a built-in provider module" do
      assert {:ok, models} = ModelsDev.fetch(Omni.Providers.OpenAI, [])

      assert models != []
      assert Enum.all?(models, &(&1.provider == Omni.Providers.OpenAI))
    end

    test "applies catalog renames for moonshot and ollama" do
      assert {:ok, [_ | _]} = ModelsDev.fetch(Omni.Providers.Moonshot, [])
      assert {:ok, [_ | _] = ollama} = ModelsDev.fetch(Omni.Providers.Ollama, [])

      # The catalog reports Ollama's OpenAI-compatible endpoint; the native
      # dialect preference is re-applied by the provider's models/0.
      assert Enum.all?(ollama, &(&1.dialect == Omni.Dialects.OpenAICompletions))
    end

    test "provider_id: resolves any catalog id for a custom module" do
      assert {:ok, [_ | _] = models} = ModelsDev.fetch(CompletionsProvider, provider_id: :groq)
      assert Enum.all?(models, &(&1.provider == CompletionsProvider))

      assert {:ok, [_ | _]} = ModelsDev.fetch(CompletionsProvider, provider_id: "mistral")
    end

    test "returns :unknown_provider for a catalog id not in the snapshot" do
      assert {:error, :unknown_provider} =
               ModelsDev.fetch(CompletionsProvider, provider_id: :does_not_exist)
    end

    test "returns :unknown_provider for a custom module without provider_id" do
      assert {:error, :unknown_provider} = ModelsDev.fetch(CompletionsProvider, [])
    end
  end
end
