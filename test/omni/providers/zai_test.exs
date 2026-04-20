defmodule Omni.Providers.ZaiTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Zai

  describe "config/0" do
    test "returns expected configuration" do
      config = Zai.config()

      assert config.base_url == "https://api.z.ai/api/paas"
      assert config.api_key == {:system, "ZAI_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert Zai.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Zai.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Zai.models() do
        assert model.provider == Zai
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end
  end

  describe "build_url/2" do
    test "rewrites /v1 in the dialect path to /v4" do
      url = Zai.build_url("/v1/chat/completions", %{base_url: "https://api.z.ai/api/paas"})

      assert url == "https://api.z.ai/api/paas/v4/chat/completions"
    end

    test "passes through paths without /v1" do
      url = Zai.build_url("/health", %{base_url: "https://api.z.ai/api/paas"})

      assert url == "https://api.z.ai/api/paas/health"
    end
  end

  describe "modify_body/3" do
    test "translates reasoning_effort=none to thinking disabled" do
      body = %{"model" => "glm-4.7-flash", "reasoning_effort" => "none"}

      result = Zai.modify_body(body, %Omni.Context{}, %{})

      assert result["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "translates any positive effort to thinking enabled" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "glm-4.7-flash", "reasoning_effort" => level}

        result = Zai.modify_body(body, %Omni.Context{}, %{})

        assert result["thinking"] == %{"type" => "enabled"},
               "expected #{level} to map to enabled"

        refute Map.has_key?(result, "reasoning_effort")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "glm-4.7-flash", "messages" => []}

      result = Zai.modify_body(body, %Omni.Context{}, %{})

      assert result == body
    end
  end
end
