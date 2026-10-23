defmodule Integration.AnthropicTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Content.{Text, Thinking}

  @dir "test/support/fixtures/anthropic"

  setup do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-5-5")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      assert_text(model, "#{@dir}/text.sse")
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      # Summarized thinking: text, with a signature for replay
      assert [%Thinking{text: text, signature: signature}, %Text{}] = resp.message.content
      assert text != "" and signature != ""

      assert request.body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert request.body["output_config"] == %{"effort" => "low"}
      assert is_integer(request.body["max_tokens"])
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.anthropic.com/v1/messages", [
        {"x-api-key", "test-key"},
        {"anthropic-version", "2023-06-01"}
      ])
    end
  end
end
