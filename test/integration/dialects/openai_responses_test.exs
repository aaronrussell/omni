defmodule Integration.Dialects.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API. Provider quirks live in the provider tests.
  @dir "test/support/fixtures/dialects/openai_responses"

  setup do
    %{model: Cases.reference(:openai_responses)}
  end

  describe "cases" do
    # `input_tokens` includes the cached prefix on the wire.
    test "cache hit on turn 2", %{model: model} do
      assert_cache_hit(model, "#{@dir}/cache_1.sse", "#{@dir}/cache_2.sse")
    end

    # Cut short, the stream ends with `response.incomplete` (reason
    # `max_output_tokens`) instead of `response.completed`. The call is
    # incomplete and must not be run.
    test "response.incomplete mid tool call is :length", %{model: model} do
      {context, opts} = Cases.request(:tool_length)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/tool_length.sse", opts)

      assert resp.stop_reason == :length
      assert [%ToolUse{name: "save_note", input: input}] = resp.message.content
      assert input == %{}
      assert resp.usage.output_tokens == 40
    end

    # A reasoning item (no summary here, only encrypted content), then
    # parallel function calls. With `store: false`, turn 2 sends the item back
    # by id with its encrypted content, ahead of the calls it preceded.
    test "reasoning goes back by id on turn 2", %{model: model} do
      {context, opts} = Cases.request(:thinking_tools)
      assert {:ok, resp1} = Capture.replay(model, context, "#{@dir}/tools_1.sse", opts)
      assert_received {:replay_request, %{body: body1}}
      assert body1["include"] == ["reasoning.encrypted_content"]

      assert resp1.stop_reason == :tool_use

      assert [%Thinking{id: "rs_" <> _ = id, signature: "" <> _ = encrypted} | tool_uses] =
               resp1.message.content

      assert length(tool_uses) == 4 and Enum.all?(tool_uses, &match?(%ToolUse{}, &1))

      turn2 = tool_round(context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/tools_2.sse", opts)
      assert_received {:replay_request, %{body: body}}

      assert [_question, reasoning | rest] = body["input"]
      assert %{"type" => "reasoning", "id" => ^id, "encrypted_content" => ^encrypted} = reasoning

      assert Enum.map(rest, & &1["type"]) ==
               List.duplicate("function_call", 4) ++ List.duplicate("function_call_output", 4)

      assert resp2.stop_reason == :stop
      assert [%Thinking{id: "rs_" <> _, text: "" <> _}, %Text{}] = resp2.message.content
    end
  end

  describe "synthetic" do
    test "response.failed event returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "The model failed to generate a response."}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/failed.sse")
    end

    test "error event returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "An error occurred during streaming."}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/stream_error.sse")
    end
  end
end
