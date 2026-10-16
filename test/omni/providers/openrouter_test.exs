defmodule Omni.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenRouter
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenRouter.config())

      assert config.base_url == "https://openrouter.ai/api/v1"
      assert config.api_key == {:system, "OPENROUTER_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:openrouter)

      assert provider.module == OpenRouter
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:openrouter)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{
                 thinking_effort_field: "reasoning.effort",
                 thinking_replay_field: "reasoning_details"
               }
             }
    end
  end
end
