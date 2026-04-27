defmodule Live.OllamaTest do
  use ExUnit.Case, async: false

  @moduletag :live

  setup_all do
    Omni.Provider.load([:ollama])

    model =
      Omni.Model.new(
        id: "gemma4:latest",
        name: "gemma4:latest",
        provider: Omni.Providers.Ollama,
        dialect: Omni.Dialects.OllamaChat,
        input_modalities: [:text, :image],
        reasoning: true
      )

    Omni.Model.put(:ollama, model)
    :ok
  end

  @model {:ollama, "gemma4:latest"}

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
    LiveTests.vision_pdf(@model)
  rescue
    e in ExUnit.AssertionError ->
      assert match?({:error, {:unsupported_modality, :pdf}}, e.right)
  end

  test "roundtrip" do
    LiveTests.roundtrip(@model)
  end
end
