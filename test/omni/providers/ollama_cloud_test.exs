defmodule Omni.Providers.OllamaCloudTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OllamaCloud
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OllamaCloud.config())

      assert config.dialects[Omni.Dialects.OllamaChat][:base_url] == "https://ollama.com"
      assert config.api_key == {:system, "OLLAMA_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OllamaChat dialect" do
      {provider, models} = Loader.assemble(:ollama_cloud)

      assert provider.module == OllamaCloud
      # The catalog's Completions endpoint stays; models/2 moves every model to OllamaChat.
      assert Enum.sort(Map.keys(provider.dialects)) == [
               Omni.Dialects.OllamaChat,
               Omni.Dialects.OpenAICompletions
             ]

      assert provider.dialects[Omni.Dialects.OllamaChat].base_url == "https://ollama.com"
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OllamaChat}
      end
    end
  end
end
