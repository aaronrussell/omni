defmodule Integration.OpenAITest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking}
  alias Omni.Test.Capture

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

    test "structured output", %{model: model} do
      {_resp, request} = assert_structured_output(model, "#{@dir}/structured_output.sse")
      assert %{"type" => "json_schema", "strict" => true} = request.body["text"]["format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.openai.com/v1/responses", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  describe "cases" do
    # `input_tokens` includes the cached prefix on the wire.
    test "cache hit on turn 2", %{model: model} do
      assert_cache_hit(model, "#{@dir}/cache_1.sse", "#{@dir}/cache_2.sse")
    end
  end

  describe "synthetic" do
    test "response.failed event returns stream_error", %{model: model} do
      file = "test/support/fixtures/synthetic/openai_responses_failed.sse"

      assert {:error, {:stream_error, "The model failed to generate a response."}} =
               Capture.replay(model, Context.new("Hello"), file)
    end

    test "error event returns stream_error", %{model: model} do
      file = "test/support/fixtures/synthetic/openai_responses_stream_error.sse"

      assert {:error, {:stream_error, "An error occurred during streaming."}} =
               Capture.replay(model, Context.new("Hello"), file)
    end
  end
end
