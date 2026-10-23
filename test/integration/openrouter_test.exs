defmodule Integration.OpenRouterTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.Capture

  @dir "test/support/fixtures/openrouter"

  setup do
    {:ok, model} = Omni.get_model(:openrouter, "deepseek/deepseek-v4.1-flash")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.sse")
      assert request.body["reasoning"] == %{"effort" => "none"}
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["reasoning"] == %{"effort" => "low"}
      assert [%Thinking{text: "" <> _}, %Text{}] = resp.message.content
      assert [%{"type" => "reasoning.text"} | _] = resp.message.private.reasoning_details
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "json_schema"} = body["response_format"]
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://openrouter.ai/api/v1/chat/completions", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end

  # Each upstream's reasoning comes back in its own `reasoning_details` shape,
  # kept in `Message.private` and sent back verbatim on the next turn.
  describe "cases" do
    test "Gemini thinks with encrypted reasoning only" do
      {:ok, model} = Omni.get_model(:openrouter, "google/gemini-3.8-flash")
      {resp, _request} = assert_thinking(model, "#{@dir}/gemini_thinking.sse")

      assert [%Text{}] = resp.message.content

      assert [%{"type" => "reasoning.encrypted", "data" => "" <> _}] =
               resp.message.private.reasoning_details
    end

    test "Gemini parallel tool calls replay reasoning_details" do
      {:ok, model} = Omni.get_model(:openrouter, "google/gemini-3.8-flash")
      {context, opts} = request(:kitchen_sink)

      assert {:ok, resp1} = Capture.replay(model, context, "#{@dir}/gemini_tools_1.sse", opts)
      assert resp1.stop_reason == :tool_use
      assert [%ToolUse{id: first_id} | _] = tool_uses = resp1.message.content
      assert length(tool_uses) == 4

      # One encrypted entry, carrying the first call's id
      assert [%{"type" => "reasoning.encrypted", "id" => ^first_id} = details] =
               resp1.message.private.reasoning_details

      assert_received {:replay_request, _}

      turn2 = tool_round(context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/gemini_tools_2.sse", opts)
      assert_received {:replay_request, %{body: body}}

      assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert assistant["reasoning_details"] == [details]
      assert length(assistant["tool_calls"]) == 4

      assert resp2.stop_reason == :stop
      assert [%Text{text: "" <> _}] = resp2.message.content
    end

    test "Anthropic thinks with signed reasoning text" do
      {:ok, model} = Omni.get_model(:openrouter, "anthropic/claude-haiku-5.5")
      {resp, _request} = assert_thinking(model, "#{@dir}/anthropic_thinking.sse")

      assert [%Thinking{text: "" <> _}, %Text{}] = resp.message.content
      details = resp.message.private.reasoning_details
      assert Enum.all?(details, &(&1["type"] == "reasoning.text"))
      assert Enum.any?(details, &match?(%{"signature" => "" <> _}, &1))
    end
  end

  describe "synthetic" do
    test "error in a chunk returns stream_error", %{model: model} do
      file = "test/support/fixtures/openrouter/error.sse"

      assert {:error, {:stream_error, "Provider disconnected"}} =
               Capture.replay(model, Context.new("Hello"), file)
    end
  end
end
