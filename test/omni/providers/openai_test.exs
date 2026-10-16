defmodule Omni.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenAI
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenAI.config())

      assert config.base_url == "https://api.openai.com/v1"
      assert config.api_key == {:system, "OPENAI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAIResponses dialect" do
      {provider, models} = Loader.assemble(:openai)

      assert provider.module == OpenAI
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAIResponses]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAIResponses}
      end
    end
  end
end
