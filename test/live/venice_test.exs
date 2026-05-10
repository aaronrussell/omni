defmodule Live.VeniceTest do
  use ExUnit.Case, async: false

  @moduletag :live

  setup_all do
    Omni.Provider.load([:venice])
    :ok
  end

  @model {:venice, "qwen3-6-27b"}

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
  end

  test "roundtrip" do
    LiveTests.roundtrip(@model)
  end
end
