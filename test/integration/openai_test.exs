defmodule Integration.OpenAITest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Content.{Text, Thinking}

  @dir "test/support/fixtures/openai"

  setup do
    {:ok, model} = Omni.get_model(:openai, "gpt-6-luna")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")

      assert request.body["reasoning"] == %{"effort" => "none"}
      assert request.body["store"] == false
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning"] == %{"effort" => "low", "summary" => "auto"}
      assert [%Thinking{text: "" <> _}, %Text{}] = resp.message.content
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema", "strict" => true} = body["text"]["format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.openai.com/v1/responses", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end
end
