defmodule Omni.Providers.MoonshotTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Moonshot
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Moonshot.config())

      assert config.base_url == "https://api.moonshot.ai/v1"
      assert config.api_key == {:system, "MOONSHOT_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:moonshotai)

      assert provider.module == Moonshot
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
      {provider, _models} = Loader.assemble(:moonshotai)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{thinking_toggle_format: :thinking_type}
             }
    end
  end
end
