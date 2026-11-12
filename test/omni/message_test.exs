defmodule Omni.MessageTest do
  use ExUnit.Case, async: true

  alias Omni.Content.Text
  alias Omni.Message

  describe "new/1" do
    test "creates user message from string" do
      msg = Message.new("hello")
      assert msg.role == :user
      assert [%Text{text: "hello"}] = msg.content
      assert %DateTime{} = msg.timestamp
    end

    test "normalises string content to Text block" do
      msg = Message.new(role: :user, content: "hello")
      assert [%Text{text: "hello"}] = msg.content
    end

    test "passes through list content unchanged" do
      blocks = [%Text{text: "hello"}]
      msg = Message.new(role: :user, content: blocks)
      assert msg.content == blocks
    end

    test "wraps strings in a content list in Text blocks" do
      attachment = Omni.Content.Attachment.new({:url, "https://example.com/a.png"}, "image/png")
      msg = Message.new(role: :user, content: ["What's this?", attachment])
      assert [%Text{text: "What's this?"}, ^attachment] = msg.content
    end

    test "content defaults to empty list when omitted" do
      msg = Message.new(role: :user)
      assert msg.content == []
    end

    test "auto-assigns timestamp" do
      msg = Message.new(role: :user, content: "hello")
      assert %DateTime{} = msg.timestamp
    end

    test "preserves explicit timestamp" do
      ts = ~U[2025-01-01 00:00:00Z]
      msg = Message.new(role: :user, content: "hello", timestamp: ts)
      assert msg.timestamp == ts
    end

    test "records a model as its reference and dialect" do
      model = Omni.Test.Fixtures.model(id: "test-model", dialect: Omni.Dialects.AnthropicMessages)
      msg = Message.new(role: :assistant, content: "hi", origin: model)

      assert msg.origin == %{
               model: {:test, "test-model"},
               dialect: Omni.Dialects.AnthropicMessages
             }
    end

    test "passes an origin map through, and defaults to nil" do
      origin = %{
        model: {:anthropic, "claude-haiku-5-5"},
        dialect: Omni.Dialects.AnthropicMessages
      }

      assert Message.new(role: :assistant, content: "hi", origin: origin).origin == origin
      assert Message.new("hi").origin == nil
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Message.new(role: :user, content: "hello", bogus: true)
      end
    end
  end
end
