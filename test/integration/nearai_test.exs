defmodule Integration.NearAITest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  # Recorded before the capture script, with older prompts, and no structured
  # output: there's no key to re-record with yet.
  @dir "test/support/fixtures/nearai"

  setup do
    {:ok, model} = Omni.get_model(:nearai, "zai-org/GLM-5.1-FP8")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse", max_tokens: 1000)

      assert request.body["max_tokens"] == 1000
      refute Map.has_key?(request.body, "max_completion_tokens")
    end

    # NEAR AI rejects thinking controls, so nothing is sent.
    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      refute Map.has_key?(request.body, "reasoning_effort")
      refute Map.has_key?(request.body, "thinking")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://cloud-api.near.ai/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end
end
