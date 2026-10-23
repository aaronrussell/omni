defmodule Integration.GroqTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/groq"

  setup do
    {:ok, model} = Omni.get_model(:groq, "openai/gpt-oss-120b")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      assert_text(model, "#{@dir}/text.sse")
    end

    # gpt-oss reasons separately on its own, so no `reasoning_format`.
    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning_effort"] == "low"
      refute Map.has_key?(request.body, "reasoning_format")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output", %{model: model} do
      {_resp, request} = assert_structured_output(model, "#{@dir}/structured_output.sse")
      assert %{"type" => "json_schema"} = request.body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/text.sse",
        "https://api.groq.com/openai/v1/chat/completions",
        [
          {"authorization", "Bearer test-key"}
        ]
      )
    end
  end
end
