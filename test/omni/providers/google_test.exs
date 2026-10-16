defmodule Omni.Providers.GoogleTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Google
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Google.config())

      assert config.base_url == "https://generativelanguage.googleapis.com/v1beta"
      assert config.api_key == {:system, "GEMINI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the GoogleGemini dialect" do
      {provider, models} = Loader.assemble(:google)

      assert provider.module == Google
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.GoogleGemini]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.GoogleGemini}
      end
    end
  end
end
