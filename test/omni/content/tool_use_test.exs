defmodule Omni.Content.ToolUseTest do
  use ExUnit.Case, async: true

  alias Omni.Content.ToolUse

  describe "new/1" do
    test "creates with all fields" do
      tool_use = ToolUse.new(id: "tu_1", name: "get_weather", input: %{"city" => "SF"})

      assert %ToolUse{
               id: "tu_1",
               name: "get_weather",
               input: %{"city" => "SF"},
               signature: nil
             } = tool_use
    end

    test "creates from map" do
      tool_use = ToolUse.new(%{id: "tu_1", name: "get_weather", input: %{}, signature: "sig"})
      assert tool_use.signature == "sig"
    end

    test "signature defaults to nil" do
      tool_use = ToolUse.new(id: "tu_1", name: "get_weather", input: %{})
      assert tool_use.signature == nil
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        ToolUse.new(id: "tu_1", name: "get_weather", input: %{}, bogus: true)
      end
    end
  end
end
