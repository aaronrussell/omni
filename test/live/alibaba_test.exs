defmodule Live.AlibabaTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  @model {:alibaba, "qwen3.6-plus"}

  setup_all do
    Omni.Provider.load([:alibaba])
  end

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
    LiveTests.vision_image(@model, thinking: false)
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
