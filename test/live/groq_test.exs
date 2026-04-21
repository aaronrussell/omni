defmodule Live.GroqTest do
  use ExUnit.Case, async: false

  @moduletag :live

  @model {:groq, "openai/gpt-oss-20b"}

  setup_all do
    Omni.Provider.load([:groq])
    :ok
  end

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
    LiveTests.vision_image({:groq, "meta-llama/llama-4-scout-17b-16e-instruct"})
  end
end
