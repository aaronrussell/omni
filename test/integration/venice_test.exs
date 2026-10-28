defmodule Integration.VeniceTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.Capture

  @dir "test/support/fixtures/venice"

  setup do
    {:ok, model} = Omni.get_model(:venice, "qwen-3-8-flash")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")
      assert request.body["reasoning"] == %{"enabled" => false}
    end

    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")
      assert request.body["reasoning"] == %{"enabled" => true}
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "thinking replay request", %{model: model} do
      {thinking, assistant} = replay_thinking(model, :thinking, "#{@dir}/thinking.sse")
      assert assistant["reasoning_content"] == thinking
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema"} = body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.venice.ai/api/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  # Venice (vLLM) packs several payloads into one chunk.
  describe "synthetic" do
    test "tool call arguments packed with finish_reason", %{model: model} do
      file = "#{@dir}/packed_tool_finish.sse"
      assert {:ok, resp} = Capture.replay(model, Context.new("Hello"), file)

      assert resp.stop_reason == :tool_use
      assert [%ToolUse{name: "calculate", input: %{"expression" => "2+2"}}] = resp.message.content
    end

    test "reasoning packed with content", %{model: model} do
      file = "#{@dir}/packed_reasoning_content.sse"
      assert {:ok, resp} = Capture.replay(model, Context.new("Hello"), file)

      assert [%Thinking{text: "Let me think about this. Done."}, %Text{text: "The answer is 42."}] =
               resp.message.content
    end
  end
end
