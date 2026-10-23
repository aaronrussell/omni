defmodule Integration.Dialects.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.{Context, Message, Request}
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API. Provider quirks live in the provider tests.
  @dir "test/support/fixtures/dialects/anthropic_messages"

  setup do
    %{model: Cases.reference(:anthropic_messages)}
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

    # A `max_tokens` stop inside the arguments stays `:length`: the call is
    # incomplete and must not be run.
    test "max_tokens mid tool call stays :length", %{model: model} do
      {context, opts} = Cases.request(:tool_length)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/tool_length.sse", opts)

      assert resp.stop_reason == :length
      assert [%ToolUse{name: "save_note", input: input}] = resp.message.content
      assert input == %{}
    end

    # Thinking, then parallel tool calls. Turn 2 sends the signed thinking back
    # ahead of the calls, as Anthropic requires with thinking on.
    test "thinking before tool use goes back signed on turn 2", %{model: model} do
      {context, opts} = Cases.request(:thinking_tools)
      assert {:ok, resp1} = Capture.replay(model, context, "#{@dir}/tools_1.sse", opts)
      assert_received {:replay_request, _}

      assert resp1.stop_reason == :tool_use

      assert [%Thinking{text: "" <> _, signature: "" <> _ = signature} | tool_uses] =
               resp1.message.content

      assert length(tool_uses) == 4 and Enum.all?(tool_uses, &match?(%ToolUse{}, &1))

      turn2 = tool_round(context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/tools_2.sse", opts)
      assert_received {:replay_request, %{body: body}}

      assert [_question, %{"content" => [thinking | calls]}, %{"content" => results}] =
               body["messages"]

      assert %{"type" => "thinking", "signature" => ^signature} = thinking
      assert Enum.map(calls, & &1["type"]) == List.duplicate("tool_use", 4)
      assert Enum.map(results, & &1["type"]) == List.duplicate("tool_result", 4)

      assert resp2.stop_reason == :stop
      assert [%Text{text: "" <> _}] = resp2.message.content
    end

    # Redacted blocks carry encrypted data and no text, and go back verbatim.
    test "redacted thinking round-trips", %{model: model} do
      {context, opts} = Cases.request(:redacted_thinking)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/redacted_thinking.sse", opts)

      {redacted, [%Text{}]} = Enum.split_with(resp.message.content, &match?(%Thinking{}, &1))
      assert length(redacted) == 3
      assert Enum.all?(redacted, &(&1.text == nil and is_binary(&1.redacted_data)))

      turn2 = %{context | messages: context.messages ++ [resp.message, Message.new("Thanks.")]}
      assert {:ok, req} = Request.build(model, turn2, Keyword.put(opts, :api_key, "test-key"))
      assert [_question, %{"content" => content}, _thanks] = req.options.json["messages"]

      assert Enum.map(redacted, &%{"type" => "redacted_thinking", "data" => &1.redacted_data}) ==
               Enum.filter(content, &(&1["type"] == "redacted_thinking"))
    end
  end

  describe "synthetic" do
    test "error event mid-stream returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "Overloaded"}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/error.sse")
    end
  end
end
