defmodule Omni.Providers.TogetherTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Together
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Together.config())

      assert config.base_url == "https://api.together.ai/v1"
      assert config.api_key == {:system, "TOGETHER_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:togetherai)

      assert provider.module == Together
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
      {provider, _models} = Loader.assemble(:togetherai)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{
                 max_tokens_field: "max_tokens",
                 thinking_toggle_format: :reasoning_enabled,
                 omit: [:cache]
               }
             }
    end
  end
end
