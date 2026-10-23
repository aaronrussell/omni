defmodule Integration.AlibabaTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/alibaba"

  setup do
    {:ok, model} = Omni.get_model(:alibaba, "qwen3.8-flash")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")
      assert request.body["enable_thinking"] == false
    end

    # An effort model: effort, no budget
    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning_effort"] == "low"
      refute Map.has_key?(request.body, "thinking_budget")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output", %{model: model} do
      {_resp, request} = assert_structured_output(model, "#{@dir}/structured_output.sse")
      assert request.body["response_format"] == %{"type" => "json_object"}
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/text.sse",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
        [{"authorization", "Bearer test-key"}]
      )
    end
  end

  describe "cases" do
    # `prompt_tokens` includes the cached prefix on the wire.
    test "cache hit on turn 2", %{model: model} do
      assert_cache_hit(model, "#{@dir}/cache_1.sse", "#{@dir}/cache_2.sse")
    end
  end
end
