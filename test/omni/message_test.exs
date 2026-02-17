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

    test "content defaults to empty list when omitted" do
      msg = Message.new(role: :user)
      assert msg.content == []
    end

    test "auto-assigns timestamp" do
      before = DateTime.utc_now()
      msg = Message.new(role: :user, content: "hello")
      after_time = DateTime.utc_now()

      assert %DateTime{} = msg.timestamp
      assert DateTime.compare(msg.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(msg.timestamp, after_time) in [:lt, :eq]
    end

    test "preserves explicit timestamp" do
      ts = ~U[2025-01-01 00:00:00Z]
      msg = Message.new(role: :user, content: "hello", timestamp: ts)
      assert msg.timestamp == ts
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Message.new(role: :user, content: "hello", bogus: true)
      end
    end
  end
end
