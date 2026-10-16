defmodule Omni.Providers.GroqTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Groq
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Groq.config())

      assert config.base_url == "https://api.groq.com/openai/v1"
      assert config.api_key == {:system, "GROQ_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:groq)

      assert provider.module == Groq
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "modify_body/4" do
    test "does not set reasoning_format when no reasoning effort" do
      body = %{"model" => "llama-3.3-70b-versatile"}

      result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

      refute Map.has_key?(result, "reasoning_format")
    end

    test "clamps xhigh to high on gpt-oss models" do
      for id <- ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "openai/gpt-oss-safeguard-20b"] do
        body = %{"model" => id, "reasoning_effort" => "xhigh"}

        result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == "high", "expected #{id} to clamp xhigh to high"
      end
    end

    test "passes low/medium/high through unchanged on gpt-oss models" do
      for level <- ["low", "medium", "high"] do
        body = %{"model" => "openai/gpt-oss-120b", "reasoning_effort" => level}

        result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == level
      end
    end

    test "passes none through unchanged on gpt-oss models" do
      body = %{"model" => "openai/gpt-oss-120b", "reasoning_effort" => "none"}

      result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "none"
    end

    test "rewrites positive efforts to default on qwen models" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "qwen/qwen3-32b", "reasoning_effort" => level}

        result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == "default",
               "expected qwen #{level} to map to default"
      end
    end

    test "passes none through unchanged on qwen models" do
      body = %{"model" => "qwen/qwen3-32b", "reasoning_effort" => "none"}

      result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "none"
    end

    test "leaves reasoning_effort untouched on non-reasoning models" do
      body = %{"model" => "llama-3.3-70b-versatile", "reasoning_effort" => "high"}

      result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning_effort"] == "high"
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "openai/gpt-oss-120b", "messages" => []}

      result = Groq.modify_body(body, nil, %Omni.Context{}, %{})

      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
