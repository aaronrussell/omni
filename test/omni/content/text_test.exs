defmodule Omni.Content.TextTest do
  use ExUnit.Case, async: true

  alias Omni.Content.Text

  describe "new/1" do
    test "creates from keyword list" do
      text = Text.new(text: "hello")
      assert %Text{text: "hello", signature: nil} = text
    end

    test "creates from string" do
      text = Text.new("hello")
      assert %Text{text: "hello", signature: nil} = text
    end

    test "creates from map" do
      text = Text.new(%{text: "hello", signature: "sig123"})
      assert %Text{text: "hello", signature: "sig123"} = text
    end

    test "signature defaults to nil" do
      text = Text.new(text: "hello")
      assert text.signature == nil
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Text.new(text: "hello", bogus: true)
      end
    end
  end
end
