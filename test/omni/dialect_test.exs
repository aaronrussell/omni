defmodule Omni.DialectTest do
  use ExUnit.Case, async: true

  alias Omni.Dialect

  describe "get/1" do
    test "resolves anthropic_messages" do
      assert {:ok, Omni.Dialects.AnthropicMessages} = Dialect.get("anthropic_messages")
    end

    test "resolves openai_completions" do
      assert {:ok, Omni.Dialects.OpenAICompletions} = Dialect.get("openai_completions")
    end

    test "resolves openai_responses" do
      assert {:ok, Omni.Dialects.OpenAIResponses} = Dialect.get("openai_responses")
    end

    test "resolves google_gemini" do
      assert {:ok, Omni.Dialects.GoogleGemini} = Dialect.get("google_gemini")
    end

    test "resolves ollama_chat" do
      assert {:ok, Omni.Dialects.OllamaChat} = Dialect.get("ollama_chat")
    end

    test "returns error for unknown dialect" do
      assert {:error, {:unknown_dialect, "nope"}} = Dialect.get("nope")
    end
  end

  describe "get!/1" do
    test "returns module for known dialect" do
      assert Omni.Dialects.AnthropicMessages = Dialect.get!("anthropic_messages")
    end

    test "raises for unknown dialect" do
      assert_raise ArgumentError, ~r/unknown_dialect/, fn ->
        Dialect.get!("nope")
      end
    end
  end
end
