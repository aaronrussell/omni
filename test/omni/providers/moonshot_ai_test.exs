defmodule Omni.Providers.MoonshotAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.MoonshotAI

  describe "config/0" do
    test "returns expected configuration" do
      config = MoonshotAI.config()

      assert config.base_url == "https://api.moonshot.ai"
      assert config.api_key == {:system, "MOONSHOT_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert MoonshotAI.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = MoonshotAI.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- MoonshotAI.models() do
        assert model.provider == MoonshotAI
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end
  end

  describe "modify_body/3" do
    test "converts reasoning_effort none to thinking disabled" do
      body = %{"model" => "kimi-k2.6", "reasoning_effort" => "none"}

      result = MoonshotAI.modify_body(body, %Omni.Context{}, %{})

      assert result["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "converts positive reasoning_effort to thinking enabled" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "kimi-k2.6", "reasoning_effort" => level}

        result = MoonshotAI.modify_body(body, %Omni.Context{}, %{})

        assert result["thinking"] == %{"type" => "enabled"},
               "expected #{level} to map to thinking enabled"

        refute Map.has_key?(result, "reasoning_effort")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "kimi-k2.6", "messages" => []}

      result = MoonshotAI.modify_body(body, %Omni.Context{}, %{})

      refute Map.has_key?(result, "thinking")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
