defmodule Omni.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Anthropic
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Anthropic.config())

      assert config.base_url == "https://api.anthropic.com/v1"
      assert config.api_key == {:system, "ANTHROPIC_API_KEY"}
      assert config.headers == %{"anthropic-version" => "2023-06-01"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the AnthropicMessages dialect" do
      {provider, models} = Loader.assemble(:anthropic)

      assert provider.module == Anthropic
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.AnthropicMessages]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.AnthropicMessages}
      end
    end
  end
end
