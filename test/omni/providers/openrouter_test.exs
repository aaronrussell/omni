defmodule Omni.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenRouter
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenRouter.config())

      assert config.dialects[Omni.Dialects.OpenAICompletions][:base_url] ==
               "https://openrouter.ai/api/v1"

      assert config.dialects[Omni.Dialects.SystemOne][:base_url] ==
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
               Omni.Dialects.SystemOne
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
      assert Enum.all?(decision, &(&1.dialects == %{decision: Omni.Dialects.SystemOne}))
      assert Enum.any?(decision, &(&1.id == "typesafe/jev-1.14"))
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
