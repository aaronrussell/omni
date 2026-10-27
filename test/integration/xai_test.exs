defmodule Integration.XAITest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Content.{Text, Thinking}

  @dir "test/support/fixtures/xai"

  defp model(id) do
    {:ok, model} = Omni.get_model(:xai, id)
    model
  end

  # Recorded on grok-4.3, which lists a "none" effort, so text switches off.
  describe "baseline" do
    setup do: %{model: model("grok-4.3")}

    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")

      assert request.body["reasoning"] == %{"effort" => "none"}
      assert request.body["store"] == false
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning"] == %{"effort" => "low", "summary" => "auto"}
      assert request.body["include"] == ["reasoning.encrypted_content"]
      assert [%Thinking{text: "" <> _, signature: "" <> _}, %Text{}] = resp.message.content
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema", "strict" => true} = body["text"]["format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.x.ai/v1/responses", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  # Models with no effort data reject `reasoning.effort` with any value.
  describe "thinking request without effort data" do
    setup do: %{model: model("grok-4.20-0309-reasoning")}

    test "thinking sends no reasoning", %{model: model} do
      body = request_body(model, :thinking)

      refute Map.has_key?(body, "reasoning")
      assert body["include"] == ["reasoning.encrypted_content"]
    end

    test "thinking off sends no reasoning", %{model: model} do
      refute Map.has_key?(request_body(model, :no_thinking), "reasoning")
    end
  end
end
