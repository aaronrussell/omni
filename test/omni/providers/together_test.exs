defmodule Omni.Providers.TogetherTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Together
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Together.config())

      assert config.dialects[Omni.Dialects.OpenAICompletions][:base_url] ==
               "https://api.together.ai/v1"

      assert config.api_key == {:system, "TOGETHER_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:togetherai)

      assert provider.module == Together
      assert Map.keys(provider.dialects) == [Omni.Dialects.OpenAICompletions]
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:togetherai)

      assert provider.dialects[Omni.Dialects.OpenAICompletions].compat == %{
               max_tokens_field: "max_tokens",
               thinking_toggle_format: :reasoning_enabled,
               thinking_replay_format: :reasoning,
               omit: [:cache]
             }
    end
  end
end
