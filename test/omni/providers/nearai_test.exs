defmodule Omni.Providers.NearAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.NearAI
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(NearAI.config())

      assert config.dialects[Omni.Dialects.OpenAICompletions][:base_url] ==
               "https://cloud-api.near.ai/v1"

      assert config.api_key == {:system, "NEARAI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:nearai)

      assert provider.module == NearAI
      assert Map.has_key?(provider.dialects, Omni.Dialects.OpenAICompletions)
      assert models != []

      for model <- models, Omni.Model.capability?(model, :text) do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end

    # Catalogued as System One at the provider URL; unverified, as NEAR AI
    # doesn't document the endpoint and there is no key to try it with.
    test "loads the catalog's decision models over System One" do
      {provider, models} = Loader.assemble(:nearai)
      decision = Enum.filter(models, &Omni.Model.capability?(&1, :decision))

      assert Enum.map(decision, & &1.id) == ["levanto/sage-1.4", "typesafe/jev-1.13"]
      assert Enum.all?(decision, &(&1.dialects == %{decision: Omni.Dialects.TypeSafeSystemOne}))

      assert provider.dialects[Omni.Dialects.TypeSafeSystemOne].base_url ==
               "https://cloud-api.near.ai/v1"
    end

    test "includes TEE-backed NEAR AI models from the catalog" do
      {_provider, models} = Loader.assemble(:nearai)

      assert Enum.any?(models, &(&1.id == "z-ai/glm-5.3"))
      assert Enum.any?(models, &(&1.id == "Qwen/Qwen3.6-35B-A3B-FP8"))
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:nearai)

      assert provider.dialects[Omni.Dialects.OpenAICompletions].compat == %{
               max_tokens_field: "max_tokens",
               omit: [:cache, :thinking, :strict_schema]
             }
    end
  end
end
