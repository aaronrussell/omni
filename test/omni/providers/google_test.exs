defmodule Omni.Providers.GoogleTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Google

  describe "config/0" do
    test "returns expected configuration" do
      config = Google.config()

      assert config.base_url == "https://generativelanguage.googleapis.com"
      assert config.auth_header == "x-goog-api-key"
      assert config.api_key == {:system, "GEMINI_API_KEY"}
    end
  end

  describe "dialect/0" do
    test "returns GoogleGemini dialect" do
      assert Google.dialect() == Omni.Dialects.GoogleGemini
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Google.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Google.models() do
        assert model.provider == Google
        assert model.dialect == Omni.Dialects.GoogleGemini
      end
    end
  end

  describe "authenticate/2" do
    test "sets x-goog-api-key header without Bearer prefix" do
      req = Req.new()

      {:ok, authed} =
        Google.authenticate(req, %{api_key: "test-key-123", auth_header: "x-goog-api-key"})

      assert Req.Request.get_header(authed, "x-goog-api-key") == ["test-key-123"]
    end

    test "returns error when api_key is nil" do
      req = Req.new()

      assert {:error, :no_api_key} = Google.authenticate(req, %{api_key: nil})
    end
  end
end
