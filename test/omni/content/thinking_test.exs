defmodule Omni.Content.ThinkingTest do
  use ExUnit.Case, async: true

  alias Omni.Content.Thinking

  describe "new/1" do
    test "creates from keyword list" do
      thinking = Thinking.new(text: "reasoning", signature: "sig")
      assert %Thinking{text: "reasoning", signature: "sig"} = thinking
    end

    test "creates from map" do
      thinking = Thinking.new(%{text: "reasoning"})
      assert %Thinking{text: "reasoning", signature: nil} = thinking
    end

    test "nil text represents redacted thinking" do
      thinking = Thinking.new(text: nil, signature: "sig")
      assert thinking.text == nil
      assert thinking.signature == "sig"
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Thinking.new(text: "reasoning", bogus: true)
      end
    end
  end
end
