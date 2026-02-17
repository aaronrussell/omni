defmodule Omni.Content.ToolResultTest do
  use ExUnit.Case, async: true

  alias Omni.Content.{Text, ToolResult}

  describe "new/1" do
    test "normalises string content to Text block" do
      result = ToolResult.new(tool_use_id: "tu_1", name: "get_weather", content: "sunny")
      assert [%Text{text: "sunny"}] = result.content
    end

    test "passes through list content unchanged" do
      blocks = [%Text{text: "sunny"}]
      result = ToolResult.new(tool_use_id: "tu_1", name: "get_weather", content: blocks)
      assert result.content == blocks
    end

    test "content defaults to empty list when omitted" do
      result = ToolResult.new(tool_use_id: "tu_1", name: "get_weather")
      assert result.content == []
    end

    test "is_error defaults to false" do
      result = ToolResult.new(tool_use_id: "tu_1", name: "get_weather", content: "ok")
      assert result.is_error == false
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        ToolResult.new(tool_use_id: "tu_1", name: "get_weather", bogus: true)
      end
    end
  end
end
