defmodule Omni.Providers.OllamaCloudTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OllamaCloud

  describe "config/0" do
    test "returns the cloud base_url and env api_key" do
      config = OllamaCloud.config()

      assert config.base_url == "https://ollama.com"
      assert config.api_key == {:system, "OLLAMA_API_KEY"}
    end
  end

  describe "dialect/0" do
    test "returns OllamaChat" do
      assert OllamaCloud.dialect() == Omni.Dialects.OllamaChat
    end
  end

  describe "models/0" do
    test "loads a non-empty catalog set" do
      models = OllamaCloud.models()

      assert is_list(models) and length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "re-applies the native dialect over the catalog's" do
      for model <- OllamaCloud.models() do
        assert model.provider == OllamaCloud
        assert model.dialect == Omni.Dialects.OllamaChat
      end
    end
  end
end
