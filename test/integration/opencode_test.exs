defmodule Integration.OpenCodeTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Dialects.{AnthropicMessages, GoogleGemini, OpenAICompletions, OpenAIResponses}
  alias Omni.Test.Capture

  # Zen serves each model over its upstream's dialect. Its claim is the
  # routing: the dialect and target for each. The bytes are the upstreams',
  # covered by the dialect tests.
  @dir "test/support/fixtures/opencode"

  defp model(id) do
    {:ok, model} = Omni.get_model(:opencode, id)
    model
  end

  describe "baseline: Anthropic Messages" do
    setup do: %{model: model("claude-haiku-5-5")}

    test "dialect", %{model: model} do
      assert model.dialects.text == AnthropicMessages
    end

    test "text", %{model: model} do
      assert_text(model, "#{@dir}/anthropic_text.sse")
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/anthropic_text.sse",
        "https://opencode.ai/inference/anthropic/v1/messages",
        [
          {"x-api-key", "test-key"}
        ]
      )
    end
  end

  describe "baseline: OpenAI Responses" do
    setup do: %{model: model("gpt-6-luna")}

    test "dialect", %{model: model} do
      assert model.dialects.text == OpenAIResponses
    end

    test "text", %{model: model} do
      assert_text(model, "#{@dir}/oair_text.sse")
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/oair_text.sse",
        "https://opencode.ai/inference/openai/v1/responses",
        [
          {"authorization", "Bearer test-key"}
        ]
      )
    end
  end

  describe "baseline: OpenAI Completions" do
    setup do: %{model: model("deepseek-v4.1-flash")}

    test "dialect", %{model: model} do
      assert model.dialects.text == OpenAICompletions
    end

    test "text", %{model: model} do
      assert_text(model, "#{@dir}/oaic_text.sse")
    end

    # DeepSeek reasons in the text scenario too, which sends `thinking: false`.
    test "thinking replay request", %{model: model} do
      {thinking, assistant} = replay_thinking(model, :text, "#{@dir}/oaic_text.sse")
      assert assistant["reasoning_content"] == thinking
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/oaic_text.sse",
        "https://opencode.ai/inference/openai/v1/chat/completions",
        [{"authorization", "Bearer test-key"}]
      )
    end
  end

  describe "baseline: Google Gemini" do
    setup do: %{model: model("gemini-3.8-flash")}

    test "dialect", %{model: model} do
      assert model.dialects.text == GoogleGemini
    end

    test "text", %{model: model} do
      assert_text(model, "#{@dir}/google_text.sse")
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/google_text.sse",
        "https://opencode.ai/inference/google/v1beta/models/gemini-3.8-flash:streamGenerateContent",
        [{"x-goog-api-key", "test-key"}]
      )
    end
  end

  describe "cases" do
    # Kimi K2.5 repeats the tool call id on every argument chunk, which must
    # not start a new tool use. Recorded before the capture script.
    test "Kimi tool use with the id on every chunk" do
      {context, opts} = request(:tool_use)

      assert {:ok, resp} =
               Capture.replay(model("kimi-k2.5"), context, "#{@dir}/kimi_tool_use.sse", opts)

      assert resp.stop_reason == :tool_use
      assert [%Text{}, %ToolUse{name: "get_weather", input: input}] = resp.message.content
      assert input == %{"location" => "London"}
    end

    # Mistral streams reasoning as thinking chunks in `content`, passed
    # through by Zen; the answer follows as plain strings.
    test "Mistral thinking as content chunks" do
      model = model("mistral-large-4")
      assert model.dialects.text == OpenAICompletions

      {resp, _request} = assert_thinking(model, "#{@dir}/mistral_thinking.sse")

      assert [%Thinking{text: thinking}, %Text{text: text}] = resp.message.content
      assert thinking =~ "strawberry"
      assert text =~ "8 times"
    end

    # Mistral takes its reasoning back as a leading thinking chunk, not in
    # the `reasoning_content` field the other Completions models get.
    test "Mistral thinking replays as a content chunk" do
      {thinking, assistant} =
        replay_thinking(model("mistral-large-4"), :thinking, "#{@dir}/mistral_thinking.sse")

      refute Map.has_key?(assistant, "reasoning_content")

      assert [
               %{"type" => "thinking", "thinking" => [%{"type" => "text", "text" => ^thinking}]},
               %{"type" => "text", "text" => text}
             ] = assistant["content"]

      assert text =~ "8 times"
    end
  end
end
