defmodule Omni.Providers.OllamaCloudTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OllamaCloud
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OllamaCloud.config())

      assert config.base_url == "https://ollama.com"
      assert config.api_key == {:system, "OLLAMA_API_KEY"}
      assert config.dialects == %{text: Omni.Dialects.OllamaChat}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OllamaChat dialect" do
      {provider, models} = Loader.assemble(:ollama_cloud)

      assert provider.module == OllamaCloud
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OllamaChat]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OllamaChat}
      end
    end
  end
end
