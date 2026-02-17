defmodule Omni.ContextTest do
  use ExUnit.Case, async: true

  alias Omni.Context
  alias Omni.Content.Text
  alias Omni.Message

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
end
