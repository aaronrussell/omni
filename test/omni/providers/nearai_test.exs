defmodule Omni.Providers.NearAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.NearAI
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(NearAI.config())

      assert config.base_url == "https://cloud-api.near.ai/v1"
      assert config.api_key == {:system, "NEARAI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:nearai)

      assert provider.module == NearAI
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end

    test "includes TEE-backed NEAR AI models from the catalog" do
      {_provider, models} = Loader.assemble(:nearai)

      assert Enum.any?(models, &(&1.id == "zai-org/GLM-5.1-FP8"))
      assert Enum.any?(models, &(&1.id == "Qwen/Qwen3.6-35B-A3B-FP8"))
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:nearai)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{
                 max_tokens_field: "max_tokens",
                 omit: [:cache, :thinking, :strict_schema]
               }
             }
    end
  end
end
