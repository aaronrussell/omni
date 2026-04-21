defmodule Live.OpenAITest do
  use ExUnit.Case, async: false

  @moduletag :live

  @model {:openai, "gpt-5.4-nano"}

  test "text generation" do
    LiveTests.text_generation(@model)
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
    LiveTests.vision_pdf({:openai, "gpt-5.4"})
  end

  test "roundtrip" do
    LiveTests.roundtrip(@model)
  end
end
