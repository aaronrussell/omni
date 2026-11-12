defmodule Omni.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenRouter
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenRouter.config())

      assert config.dialects[Omni.Dialects.OpenAICompletions][:base_url] ==
               "https://openrouter.ai/api/v1"

      assert config.dialects[Omni.Dialects.TypeSafeSystemOne][:base_url] ==
               "https://openrouter.ai/api/v1"

      assert config.api_key == {:system, "OPENROUTER_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:openrouter)

      assert provider.module == OpenRouter

      assert Enum.sort(Map.keys(provider.dialects)) == [
               Omni.Dialects.OpenAICompletions,
               Omni.Dialects.TypeSafeSystemOne
             ]

      assert models != []

      for model <- models, Omni.Model.capability?(model, :text) do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end

    test "loads the catalog's decision models over System One" do
      {_provider, models} = Loader.assemble(:openrouter)
      decision = Enum.filter(models, &Omni.Model.capability?(&1, :decision))

      assert length(decision) >= 20
      assert Enum.all?(decision, &(&1.dialects == %{decision: Omni.Dialects.TypeSafeSystemOne}))
      assert Enum.any?(decision, &(&1.id == "typesafe/jev-1.14"))
    end
  end

  describe "modify_body/4" do
    setup do
      {:ok, claude} = Omni.get_model(:openrouter, "anthropic/claude-haiku-5.5")
      {:ok, gemini} = Omni.get_model(:openrouter, "google/gemini-3.8-flash")
      %{claude: claude, gemini: gemini, context: Omni.Context.new()}
    end

    test "Claude gets top-level cache_control for :short", %{claude: claude, context: context} do
      body = OpenRouter.modify_body(%{"model" => claude.id}, claude, context, %{cache: :short})
      assert body["cache_control"] == %{"type" => "ephemeral"}
    end

    test "Claude gets a 1h TTL for :long, without OpenAI's retention field",
         %{claude: claude, context: context} do
      body = %{"prompt_cache_retention" => "24h"}
      body = OpenRouter.modify_body(body, claude, context, %{cache: :long})

      assert body == %{"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}}
    end

    test "Claude without :cache is unchanged", %{claude: claude, context: context} do
      assert OpenRouter.modify_body(%{}, claude, context, %{}) == %{}
    end

    test "other models are unchanged", %{gemini: gemini, context: context} do
      body = %{"prompt_cache_retention" => "24h"}
      assert OpenRouter.modify_body(body, gemini, context, %{cache: :long}) == body
    end

    test "Claude moved to another dialect is unchanged", %{claude: claude, context: context} do
      claude = put_in(claude.dialects.text, Omni.Dialects.AnthropicMessages)
      assert OpenRouter.modify_body(%{}, claude, context, %{cache: :short}) == %{}
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:openrouter)

      assert provider.dialects[Omni.Dialects.OpenAICompletions].compat == %{
               thinking_effort_field: "reasoning.effort",
               thinking_replay_format: :reasoning_details
             }
    end
  end
end
