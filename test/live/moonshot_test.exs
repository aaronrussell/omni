defmodule Live.MoonshotTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  @model {:moonshot, "kimi-k2.6"}

  test "text generation" do
    LiveTests.text_generation(@model, thinking: false)
  end

  test "thinking" do
    LiveTests.thinking(@model)
  end

  test "tool use" do
    LiveTests.tool_use(@model)
  end

  test "structured output" do
    LiveTests.structured_output(@model)
  end

  test "vision (image)" do
    LiveTests.vision_image(@model)
  end

  test "vision (pdf)" do
    LiveTests.vision_pdf(@model)
  rescue
    e in ExUnit.AssertionError ->
      assert match?({:error, {:unsupported_modality, :pdf}}, e.right)
  end

  test "roundtrip" do
    LiveTests.roundtrip(@model)
  end
end
