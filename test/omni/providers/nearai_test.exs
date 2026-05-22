defmodule Omni.Providers.NearAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.NearAI

  describe "config/0" do
    test "returns expected configuration" do
      config = NearAI.config()

      assert config.base_url == "https://cloud-api.near.ai"
      assert config.api_key == {:system, "NEARAI_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert NearAI.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = NearAI.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- NearAI.models() do
        assert model.provider == NearAI
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end

    test "includes TEE-backed NEAR AI models from the catalog" do
      models = NearAI.models()

      assert Enum.any?(models, &(&1.id == "zai-org/GLM-5.1-FP8"))
      assert Enum.any?(models, &(&1.id == "Qwen/Qwen3-30B-A3B-Instruct-2507"))
    end
  end

  describe "modify_body/3" do
    test "renames max_completion_tokens to max_tokens" do
      body = %{"model" => "test", "max_completion_tokens" => 128}

      result = NearAI.modify_body(body, %Omni.Context{}, %{})

      assert result["max_tokens"] == 128
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "preserves an existing max_tokens value" do
      body = %{"model" => "test", "max_completion_tokens" => 128, "max_tokens" => 64}

      result = NearAI.modify_body(body, %Omni.Context{}, %{})

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

      result = NearAI.modify_body(body, %Omni.Context{}, %{})

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

      result = NearAI.modify_body(body, %Omni.Context{}, %{})

      json_schema = result["response_format"]["json_schema"]
      assert json_schema["name"] == "output"
      assert json_schema["schema"] == %{"type" => "object"}
      refute Map.has_key?(json_schema, "strict")
    end
  end

  describe "authenticate/2" do
    test "sets Bearer authorization header" do
      req = Req.new()

      {:ok, authed} = NearAI.authenticate(req, %{api_key: "nearai-test-key"})

      assert Req.Request.get_header(authed, "authorization") == ["Bearer nearai-test-key"]
    end

    test "returns error when api_key is nil" do
      req = Req.new()

      assert {:error, :no_api_key} = NearAI.authenticate(req, %{api_key: nil})
    end
  end
end
