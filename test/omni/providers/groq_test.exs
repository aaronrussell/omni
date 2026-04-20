defmodule Omni.Providers.GroqTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Groq

  describe "config/0" do
    test "returns expected configuration" do
      config = Groq.config()

      assert config.base_url == "https://api.groq.com/openai"
      assert config.api_key == {:system, "GROQ_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert Groq.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Groq.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Groq.models() do
        assert model.provider == Groq
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end
  end

  describe "modify_body/3" do
    test "always sets reasoning_format to raw" do
      body = %{"model" => "llama-3.3-70b-versatile"}

      result = Groq.modify_body(body, %Omni.Context{}, %{})

      assert result["reasoning_format"] == "parsed"
    end

    test "clamps xhigh to high on gpt-oss models" do
      for id <- ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "openai/gpt-oss-safeguard-20b"] do
        body = %{"model" => id, "reasoning_effort" => "xhigh"}

        result = Groq.modify_body(body, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == "high", "expected #{id} to clamp xhigh to high"
      end
    end

    test "passes low/medium/high through unchanged on gpt-oss models" do
      for level <- ["low", "medium", "high"] do
        body = %{"model" => "openai/gpt-oss-120b", "reasoning_effort" => level}

        result = Groq.modify_body(body, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == level
      end
    end

    test "passes none through unchanged on gpt-oss models" do
      body = %{"model" => "openai/gpt-oss-120b", "reasoning_effort" => "none"}

      result = Groq.modify_body(body, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "none"
    end

    test "rewrites positive efforts to default on qwen models" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "qwen/qwen3-32b", "reasoning_effort" => level}

        result = Groq.modify_body(body, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == "default",
               "expected qwen #{level} to map to default"
      end
    end

    test "passes none through unchanged on qwen models" do
      body = %{"model" => "qwen/qwen3-32b", "reasoning_effort" => "none"}

      result = Groq.modify_body(body, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "none"
    end

    test "leaves reasoning_effort untouched on non-reasoning models" do
      body = %{"model" => "llama-3.3-70b-versatile", "reasoning_effort" => "high"}

      result = Groq.modify_body(body, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "high"
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "openai/gpt-oss-120b", "messages" => []}

      result = Groq.modify_body(body, %Omni.Context{}, %{})

      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
