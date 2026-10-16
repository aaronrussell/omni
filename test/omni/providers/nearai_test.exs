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

  describe "modify_body/4" do
    test "renames max_completion_tokens to max_tokens" do
      body = %{"model" => "test", "max_completion_tokens" => 128}

      result = NearAI.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["max_tokens"] == 128
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "preserves an existing max_tokens value" do
      body = %{"model" => "test", "max_completion_tokens" => 128, "max_tokens" => 64}

      result = NearAI.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["max_tokens"] == 64
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "drops unsupported OpenAI-only fields" do
      body = %{
        "model" => "test",
        "prompt_cache_retention" => "24h",
        "reasoning_effort" => "high",
        "store" => true
      }

      result = NearAI.modify_body(body, nil, %Omni.Context{}, %{})

      refute Map.has_key?(result, "prompt_cache_retention")
      refute Map.has_key?(result, "reasoning_effort")
      refute Map.has_key?(result, "store")
    end

    test "removes strict mode from json_schema response_format" do
      body = %{
        "model" => "test",
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "output",
            "strict" => true,
            "schema" => %{"type" => "object"}
          }
        }
      }

      result = NearAI.modify_body(body, nil, %Omni.Context{}, %{})

      json_schema = result["response_format"]["json_schema"]
      assert json_schema["name"] == "output"
      assert json_schema["schema"] == %{"type" => "object"}
      refute Map.has_key?(json_schema, "strict")
    end
  end
end
