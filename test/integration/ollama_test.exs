defmodule Integration.OllamaTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Test.Capture

  @dir "test/support/fixtures/ollama"

  # Local models aren't in the catalog.
  setup do
    model =
      Omni.Model.new(
        id: "qwen3.8:27b-mlx",
        name: "qwen3.8:27b-mlx",
        provider: :ollama,
        thinking: true
      )

    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      {_resp, request} = assert_text(model, "#{@dir}/text.ndjson")
      assert request.body["think"] == false
    end

    test "thinking", %{model: model} do
      {_resp, request} = assert_thinking(model, "#{@dir}/thinking.ndjson")
      assert request.body["think"] == true
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.ndjson")
    end

    test "structured output", %{model: model} do
      {_resp, request} = assert_structured_output(model, "#{@dir}/structured_output.ndjson")
      assert %{"type" => "object", "required" => ["name", "color"]} = request.body["format"]
    end

    test "target", %{model: model} do
      request = assert_target(model, "#{@dir}/text.ndjson", "http://localhost:11434/api/chat", [])
      refute List.keymember?(request.headers, "authorization", 0)
    end
  end

  describe "synthetic" do
    test "error in the stream returns stream_error", %{model: model} do
      file = "test/support/fixtures/synthetic/ollama_error.ndjson"

      assert {:error, {:stream_error, "an error was encountered while running the model"}} =
               Capture.replay(model, Context.new("Hello"), file)
    end
  end
end
