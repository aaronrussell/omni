defmodule Omni.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Omni.Provider
  alias Omni.Providers.OpenAI

  describe "config/0" do
    test "returns expected configuration" do
      config = OpenAI.config()

      assert config.base_url == "https://api.openai.com"
      assert config.api_key == {:system, "OPENAI_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAIResponses dialect" do
      assert OpenAI.dialect() == Omni.Dialects.OpenAIResponses
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = OpenAI.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- OpenAI.models() do
        assert model.provider == OpenAI
        assert model.dialect == Omni.Dialects.OpenAIResponses
      end
    end
  end

  describe "new_request/4 integration" do
    test "builds request with correct URL and Bearer auth" do
      {:ok, req} =
        Provider.new_request(OpenAI, "/v1/responses", %{"model" => "test"},
          api_key: "sk-test-123"
        )

      assert URI.to_string(req.url) == "https://api.openai.com/v1/responses"
      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test-123"]
    end
  end

  describe "authenticate/2" do
    test "sets Bearer authorization header" do
      req = Req.new()

      {:ok, authed} = OpenAI.authenticate(req, api_key: "sk-test-123")

      assert Req.Request.get_header(authed, "authorization") == ["Bearer sk-test-123"]
    end

    test "returns error when api_key is nil" do
      req = Req.new()

      assert {:error, :no_api_key} = OpenAI.authenticate(req, api_key: nil)
    end
  end
end
