defmodule Live.ZaiTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  setup_all do
    Omni.Provider.load([:zai])

    vision_model =
      Omni.Model.new(
        id: "glm-4.6v-flash",
        name: "glm-4.6v-flash",
        provider: Omni.Providers.Zai,
        dialect: Omni.Dialects.OpenAICompletions,
        input_modalities: [:text, :image],
        reasoning: true
      )

    Omni.Model.put(:zai, vision_model)
    :ok
  end

  @model {:zai, "glm-4.5-flash"}

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
    LiveTests.vision_image({:zai, "glm-4.6v-flash"})
  end

  # test "vision (pdf)" do
  #  LiveTests.vision_pdf({:zai, "glm-5v-turbo"})
  # end
end
