defmodule Integration.TogetherTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/togetherai"

  defp model(id) do
    {:ok, model} = Omni.get_model(:togetherai, id)
    model
  end

  # Recorded on Qwen3.5 9B, a toggle-only hybrid model, so text switches off.
  describe "baseline" do
    setup do: %{model: model("Qwen/Qwen3.5-9B")}

    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")

      assert request.body["reasoning"] == %{"enabled" => false}
      refute Map.has_key?(request.body, "reasoning_effort")
    end

    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning"] == %{"enabled" => true}
      refute Map.has_key?(request.body, "reasoning_effort")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema"} = body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.together.ai/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  # Effort models take the effort; the toggle only switches them off.
  describe "thinking request with efforts and a toggle" do
    setup do: %{model: model("zai-org/GLM-5.2")}

    test "thinking sends the nearest effort", %{model: model} do
      body = request_body(model, :thinking)

      assert body["reasoning_effort"] == "high"
      refute Map.has_key?(body, "reasoning")
    end

    test "thinking off sends reasoning disabled", %{model: model} do
      body = request_body(model, :no_thinking)

      assert body["reasoning"] == %{"enabled" => false}
      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  # gpt-oss lists efforts but no toggle: it can't be switched off.
  describe "thinking request without a toggle" do
    setup do: %{model: model("openai/gpt-oss-120b")}

    test "thinking sends the effort", %{model: model} do
      assert request_body(model, :thinking)["reasoning_effort"] == "low"
    end

    test "thinking off sends nothing", %{model: model} do
      body = request_body(model, :no_thinking)

      refute Map.has_key?(body, "reasoning")
      refute Map.has_key?(body, "reasoning_effort")
    end
  end
end
