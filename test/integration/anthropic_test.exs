defmodule Integration.AnthropicTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking}
  alias Omni.Test.Capture

  @dir "test/support/fixtures/anthropic"

  setup do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-5-5")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      assert_text(model, "#{@dir}/text.sse")
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      # Summarized thinking: text, with a signature for replay
      assert [%Thinking{text: text, signature: signature}, %Text{}] = resp.message.content
      assert text != "" and signature != ""

      assert request.body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert request.body["output_config"] == %{"effort" => "low"}
      assert is_integer(request.body["max_tokens"])
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output", %{model: model} do
      assert_structured_output(model, "#{@dir}/structured_output.sse")
    end

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.sse", "https://api.anthropic.com/v1/messages", [
        {"x-api-key", "test-key"},
        {"anthropic-version", "2023-06-01"}
      ])
    end
  end

  describe "cases" do
    # Turn 1 writes the system prompt; turn 2 reads it back. The hit depends on
    # the prefix re-encoding byte-identically, including turn 1's signed
    # thinking (Haiku 5.5 thinks by default). The last-message breakpoint has
    # moved, so turn 2 also writes. Anthropic reports `input_tokens` without
    # the cached prefix, the meaning Omni's usage gives it on every dialect.
    test "cache hit on turn 2", %{model: model} do
      {context, opts} = request(:cache_usage)
      assert {:ok, resp1} = Capture.replay(model, context, "#{@dir}/cache_1.sse", opts)
      assert_received {:replay_request, _}
      assert resp1.usage.cache_write_tokens > 0
      assert resp1.usage.cache_read_tokens == 0

      turn2 = follow_up(:cache_usage, context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/cache_2.sse", opts)
      assert_received {:replay_request, %{body: body}}

      assert [%{"cache_control" => %{"type" => "ephemeral"}}] = body["system"]

      assert [_question, %{"content" => [thinking, _text]}, %{"content" => [follow_up]}] =
               body["messages"]

      assert %{"type" => "thinking", "signature" => "" <> _} = thinking
      assert %{"cache_control" => %{"type" => "ephemeral"}} = follow_up

      assert resp2.usage.cache_read_tokens == resp1.usage.cache_write_tokens
      assert resp2.usage.cache_write_tokens > 0
      assert resp2.usage.input_tokens < resp2.usage.cache_read_tokens
    end
  end

  describe "synthetic" do
    test "error event mid-stream returns stream_error", %{model: model} do
      file = "test/support/fixtures/synthetic/anthropic_error.sse"

      assert {:error, {:stream_error, "Overloaded"}} =
               Capture.replay(model, Context.new("Hello"), file)
    end
  end
end
