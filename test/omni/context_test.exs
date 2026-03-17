defmodule Omni.ContextTest do
  use ExUnit.Case, async: true

  alias Omni.Context
  alias Omni.Content.{Text, ToolResult, ToolUse}
  alias Omni.{Message, Response, Turn, Usage}

  describe "new/1" do
    test "creates from keyword list" do
      ctx = Context.new(system: "You are helpful.", messages: [], tools: [])

      assert %Context{system: "You are helpful.", messages: [], tools: []} = ctx
    end

    test "creates from map" do
      ctx = Context.new(%{system: "Be concise."})
      assert ctx.system == "Be concise."
    end

    test "defaults system to nil" do
      ctx = Context.new(messages: [])
      assert ctx.system == nil
    end

    test "defaults messages to empty list" do
      ctx = Context.new(system: "Hi")
      assert ctx.messages == []
    end

    test "defaults tools to empty list" do
      ctx = Context.new(system: "Hi")
      assert ctx.tools == []
    end

    test "creates from string as single user message" do
      ctx = Context.new("Hello")

      assert ctx.system == nil
      assert [%Message{role: :user, content: [%Text{text: "Hello"}]}] = ctx.messages
    end

    test "creates from list of messages" do
      messages = [Message.new("Hello"), Message.new(role: :assistant, content: "Hi")]
      ctx = Context.new(messages)

      assert ctx.messages == messages
      assert ctx.system == nil
      assert ctx.tools == []
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Context.new(system: "Hi", bogus: true)
      end
    end
  end

  describe "push/2" do
    test "appends a single message" do
      ctx = Context.new("Hello")
      reply = Message.new(role: :assistant, content: "Hi there")

      ctx = Context.push(ctx, reply)

      assert length(ctx.messages) == 2
      assert Enum.at(ctx.messages, 1).role == :assistant
    end

    test "appends a list of messages" do
      ctx = Context.new("Hello")

      messages = [
        Message.new(role: :assistant, content: "Hi"),
        Message.new(role: :user, content: "How are you?")
      ]

      ctx = Context.push(ctx, messages)

      assert length(ctx.messages) == 3
      assert Enum.at(ctx.messages, 1).role == :assistant
      assert Enum.at(ctx.messages, 2).role == :user
    end

    test "extracts messages from a response" do
      ctx = Context.new("Use the tool")

      assistant_msg =
        Message.new(
          role: :assistant,
          content: [ToolUse.new(id: "1", name: "search", input: %{})]
        )

      tool_msg =
        Message.new(
          role: :user,
          content: [ToolResult.new(tool_use_id: "1", name: "search", content: "result")]
        )

      final_msg = Message.new(role: :assistant, content: "Here's what I found")

      response =
        Response.new(
          message: final_msg,
          model: nil,
          stop_reason: :stop,
          turn: Turn.new(usage: Usage.new([]), messages: [assistant_msg, tool_msg, final_msg])
        )

      ctx = Context.push(ctx, response)

      assert length(ctx.messages) == 4
      assert [_user, ^assistant_msg, ^tool_msg, ^final_msg] = ctx.messages
    end

    test "preserves existing context fields" do
      ctx = Context.new(system: "Be helpful", messages: [Message.new("Hi")])
      ctx = Context.push(ctx, Message.new(role: :assistant, content: "Hello"))

      assert ctx.system == "Be helpful"
      assert ctx.tools == []
      assert length(ctx.messages) == 2
    end
  end
end
