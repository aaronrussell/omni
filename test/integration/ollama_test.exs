defmodule Integration.OllamaTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/ollama"

  # Local models aren't in the catalog.
  setup do
    model =
      Omni.Model.new(
        id: "qwen3.8:27b-mlx",
        name: "qwen3.8:27b-mlx",
        provider: :ollama,
        dialects: %{text: Omni.Dialects.OllamaChat},
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

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)
      assert %{"type" => "object", "required" => ["name", "color"]} = body["format"]
    end

    test "target", %{model: model} do
      request = assert_target(model, "#{@dir}/text.ndjson", "http://localhost:11434/api/chat", [])
      refute List.keymember?(request.headers, "authorization", 0)
    end
  end
end
