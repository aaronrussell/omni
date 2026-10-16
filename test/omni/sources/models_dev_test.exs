defmodule Omni.Sources.ModelsDevTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Omni.Provider
  alias Omni.Sources.ModelsDev

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

  describe "transform_provider/2 eligibility" do
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

      models = ModelsDev.transform_provider(data, "test")

      assert Enum.map(models, & &1.id) == ["kept"]
    end

    test "rejects models with missing or malformed modalities without crashing" do
      data =
        provider_data([
          model_entry("kept"),
          model_entry("no-modalities", %{}) |> Map.delete("modalities"),
          model_entry("weird-modalities", %{"modalities" => "text"})
        ])

      models = ModelsDev.transform_provider(data, "test")

      assert Enum.map(models, & &1.id) == ["kept"]
    end
  end

  describe "transform_provider/2 dialect resolution" do
    test "derives the dialect from the provider-level npm package" do
      data =
        provider_data([model_entry("claude-x")], %{"npm" => "@ai-sdk/anthropic"})

      [model] = ModelsDev.transform_provider(data, "test")

      assert model.dialects.text == Omni.Dialects.AnthropicMessages
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

      models = ModelsDev.transform_provider(data, "test")
      by_id = Map.new(models, &{&1.id, &1})

      assert by_id["gpt-x"].dialects.text == Omni.Dialects.OpenAIResponses
      assert by_id["other"].dialects.text == Omni.Dialects.AnthropicMessages
    end

    test "an unmapped provider-level npm leaves the dialect empty" do
      data = provider_data([model_entry("local")], %{"npm" => "some-unknown-sdk"})

      [model] = ModelsDev.transform_provider(data, "test")

      assert model.dialects == %{}
    end

    test "skips with a warning when a model's own npm maps to no dialect" do
      data =
        provider_data([
          model_entry("own-unmapped", %{"provider" => %{"npm" => "@ai-sdk/mistral"}}),
          model_entry("kept")
        ])

      {models, log} = with_log(fn -> ModelsDev.transform_provider(data, "test") end)

      assert Enum.map(models, & &1.id) == ["kept"]
      assert log =~ "skipping test:own-unmapped: npm package @ai-sdk/mistral maps to no dialect"
      assert log =~ "loaded 1 models, skipped 1"
    end

    test "skips with a warning when a model is served from another base URL" do
      data =
        provider_data(
          [
            model_entry("elsewhere", %{"provider" => %{"api" => "https://other.test/v1"}}),
            model_entry("same", %{"provider" => %{"api" => "https://api.test/v1"}}),
            model_entry("kept")
          ],
          %{"api" => "https://api.test/v1"}
        )

      {models, log} = with_log(fn -> ModelsDev.transform_provider(data, "test") end)

      assert Enum.map(models, & &1.id) == ["kept", "same"]
      assert log =~ "skipping test:elsewhere: served from https://other.test/v1"
    end
  end

  describe "transform_provider/2 field mapping" do
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

      [model] = ModelsDev.transform_provider(data, "test")

      assert %Omni.Model{
               name: "full",
               provider: nil,
               thinking: true,
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

      [model] = ModelsDev.transform_provider(data, "test")

      assert %Omni.Model{
               input_cost: 0,
               output_cost: 0,
               cache_read_cost: 0,
               cache_write_cost: 0,
               context_size: 0,
               max_output_tokens: 0,
               thinking: false,
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

      [model] = ModelsDev.transform_provider(data, "test")

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
        with_log(fn -> ModelsDev.transform_provider(data, "test") end)

      assert Enum.map(models, & &1.id) == ["kept"]
      assert log =~ "skipping test:bad-date"
    end

    test "sorts models by id" do
      data = provider_data([model_entry("zeta"), model_entry("alpha"), model_entry("mid")])

      models = ModelsDev.transform_provider(data, "test")

      assert Enum.map(models, & &1.id) == ["alpha", "mid", "zeta"]
    end
  end

  describe "fetch/2 against the bundled snapshot" do
    test "returns the provider record and its models" do
      assert {:ok, %Provider{} = provider, models} = ModelsDev.fetch(:openai, [])

      assert provider.id == :openai
      assert provider.name == "OpenAI"
      assert provider.api_key == {:system, "OPENAI_API_KEY"}
      assert provider.dialects == %{text: [Omni.Dialects.OpenAIResponses]}
      assert models != []
      assert Enum.all?(models, &(&1.provider == nil))
    end

    test "maps the catalog base URL, and leaves it unset when absent" do
      assert {:ok, %Provider{base_url: "https://api.moonshot.ai/v1"}, _} =
               ModelsDev.fetch(:moonshotai, [])

      assert {:ok, %Provider{base_url: nil}, _} = ModelsDev.fetch(:openai, [])
    end

    test "sets api_key only when the catalog lists exactly one variable" do
      assert {:ok, %Provider{api_key: nil}, _} = ModelsDev.fetch(:google, [])
    end

    test "translates canonical ids to models.dev catalog keys" do
      # snake_case atom -> kebab-case key
      assert {:ok, _, [_ | _]} = ModelsDev.fetch(:fireworks_ai, [])

      assert {:ok, provider, [_ | _] = ollama} = ModelsDev.fetch(:ollama_cloud, [])

      # The catalog reports Ollama's OpenAI-compatible endpoint; the native
      # dialect preference is re-applied by OllamaCloud's models/2.
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert Enum.all?(ollama, &(&1.dialects.text == Omni.Dialects.OpenAICompletions))
    end

    test "resolves per-model dialects for a gateway" do
      assert {:ok, _provider, models} = ModelsDev.fetch(:opencode, [])

      by_id = Map.new(models, &{&1.id, &1.dialects.text})
      assert by_id["claude-haiku-4-5"] == Omni.Dialects.AnthropicMessages
      assert by_id["gpt-5.2"] == Omni.Dialects.OpenAIResponses
      refute Map.has_key?(by_id, "mistral-large-4")
    end

    test "returns :unknown_provider for an id not in the snapshot" do
      assert {:error, :unknown_provider} = ModelsDev.fetch(:does_not_exist, [])
    end
  end
end
