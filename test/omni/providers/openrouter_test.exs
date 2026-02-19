defmodule Omni.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.Provider
  alias Omni.Providers.OpenRouter

  describe "config/0" do
    test "returns expected configuration" do
      config = OpenRouter.config()

      assert config.base_url == "https://openrouter.ai/api"
      assert config.api_key == {:system, "OPENROUTER_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert OpenRouter.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = OpenRouter.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- OpenRouter.models() do
        assert model.provider == OpenRouter
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end
  end

  describe "new_request/4 integration" do
    test "builds request with correct URL and Bearer auth" do
      {:ok, req} =
        Provider.new_request(OpenRouter, "/v1/chat/completions", %{"model" => "test"},
          api_key: "sk-or-test-123"
        )

      assert URI.to_string(req.url) == "https://openrouter.ai/api/v1/chat/completions"
      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-or-test-123"]
    end
  end

  describe "authenticate/2" do
    test "sets Bearer authorization header" do
      req = Req.new()

      {:ok, authed} = OpenRouter.authenticate(req, api_key: "sk-or-test-123")

      assert Req.Request.get_header(authed, "authorization") == ["Bearer sk-or-test-123"]
    end

    test "returns error when api_key is nil" do
      req = Req.new()

      assert {:error, :no_api_key} = OpenRouter.authenticate(req, api_key: nil)
    end
  end
end
