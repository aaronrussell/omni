defmodule Integration.MistralTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/mistral"

  defp model(id) do
    {:ok, model} = Omni.get_model(:mistral, id)
    model
  end

  # Recorded on Ministral, which doesn't reason: the free tier serves no
  # reasoning model. Mistral's thinking bytes are covered through OpenCode
  # Zen (opencode_test.exs).
  describe "baseline" do
    setup do: %{model: model("ministral-8b-2512")}

    test "text", %{model: model} do
      assert_text(model, "#{@dir}/text.sse")
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema"} = body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.mistral.ai/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  describe "thinking request" do
    setup do: %{model: model("mistral-small-2603")}

    # Mistral's reasoning models take one level: every level is "high".
    test "thinking sends the high effort", %{model: model} do
      assert request_body(model, :thinking)["reasoning_effort"] == "high"
    end

    test "thinking off sends none", %{model: model} do
      assert request_body(model, :no_thinking)["reasoning_effort"] == "none"
    end
  end
end
