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

    test "resolves the decision dialects" do
      assert {:ok, Omni.Dialects.SystemOne} = Dialect.get("systemone")
      assert {:ok, Omni.Dialects.OpenAIDecisions} = Dialect.get("openai_decisions")
    end

    test "returns error for unknown dialect" do
      assert {:error, {:unknown_dialect, "nope"}} = Dialect.get("nope")
    end
  end

  # A capability behaviour without the base Omni.Dialect.
  defmodule OnlyText do
    @behaviour Omni.Dialect.Text
    def option_schema, do: %{}
    def handle_path(_model, _opts), do: "/"
    def handle_body(_model, _context, _opts), do: %{}
    def handle_event(_event, _model), do: []
  end

  describe "capability/1" do
    test "every built-in dialect generates text" do
      assert Omni.Dialect.capability(Omni.Dialects.AnthropicMessages) == :text
      assert Omni.Dialect.capability(Omni.Dialects.OllamaChat) == :text
    end

    test "decision dialects serve decisions" do
      assert Omni.Dialect.capability(Omni.Dialects.SystemOne) == :decision
      assert Omni.Dialect.capability(Omni.Dialects.OpenAIDecisions) == :decision
    end

    test "a module that is not a dialect has none" do
      assert Omni.Dialect.capability(String) == nil
      assert Omni.Dialect.capability(NotAModule) == nil
    end

    test "a capability behaviour without the base is not a dialect" do
      assert Code.ensure_loaded?(OnlyText)
      assert Omni.Dialect.capability(OnlyText) == nil
    end
  end

  describe "use Omni.Dialect" do
    test "declares the base and the capability behaviour" do
      behaviours =
        Omni.Dialects.SystemOne.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Omni.Dialect in behaviours
      assert Omni.Dialect.Decision in behaviours
    end

    test "rejects an unknown capability" do
      assert_raise ArgumentError, ~r/expects a capability/, fn ->
        Code.eval_string("""
        defmodule Omni.DialectTest.BadCapability do
          use Omni.Dialect, :audio
        end
        """)
      end
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
