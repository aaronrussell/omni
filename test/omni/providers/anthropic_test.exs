defmodule Omni.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Omni.Provider
  alias Omni.Providers.Anthropic

  describe "config/0" do
    test "returns expected configuration" do
      config = Anthropic.config()

      assert config.base_url == "https://api.anthropic.com"
      assert config.auth_header == "x-api-key"
      assert config.api_key == {:system, "ANTHROPIC_API_KEY"}
      assert config.headers == %{"anthropic-version" => "2023-06-01"}
    end
  end

  describe "dialect/0" do
    test "returns AnthropicMessages dialect" do
      assert Anthropic.dialect() == Omni.Dialects.AnthropicMessages
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Anthropic.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Anthropic.models() do
        assert model.provider == Anthropic
        assert model.dialect == Omni.Dialects.AnthropicMessages
      end
    end
  end

  describe "new_request/4 integration" do
    test "builds request with correct URL and headers" do
      {:ok, req} =
        Provider.new_request(Anthropic, "/v1/messages", %{"model" => "test"},
          api_key: "sk-ant-test"
        )

      assert URI.to_string(req.url) == "https://api.anthropic.com/v1/messages"
      assert Req.Request.get_header(req, "x-api-key") == ["sk-ant-test"]
      assert Req.Request.get_header(req, "anthropic-version") == ["2023-06-01"]
    end
  end

  describe "authenticate/2" do
    test "sets x-api-key header with literal key" do
      req = Req.new()

      {:ok, authed} =
        Anthropic.authenticate(req, api_key: "sk-ant-test", auth_header: "x-api-key")

      assert Req.Request.get_header(authed, "x-api-key") == ["sk-ant-test"]
    end
  end
end
