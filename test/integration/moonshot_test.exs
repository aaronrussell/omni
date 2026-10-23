defmodule Integration.MoonshotTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/moonshotai"

  setup do
    {:ok, model} = Omni.get_model(:moonshotai, "kimi-k3")
    %{model: model}
  end

  describe "baseline" do
    # K3 always reasons: no off switch, so `thinking: false` sends nothing.
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")
      refute Map.has_key?(request.body, "thinking")
    end

    # An effort model: effort, not the on/off switch
    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning_effort"] == "low"
      refute Map.has_key?(request.body, "thinking")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema"} = body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.moonshot.ai/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end
end
