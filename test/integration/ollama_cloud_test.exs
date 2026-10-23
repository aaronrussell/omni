defmodule Integration.OllamaCloudTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  # No structured output: Ollama Cloud doesn't enforce `format`.
  @dir "test/support/fixtures/ollama_cloud"

  setup do
    {:ok, model} = Omni.get_model(:ollama_cloud, "gemma4:31b")
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

    test "target", %{model: model} do
      assert_target(model, "#{@dir}/text.ndjson", "https://ollama.com/api/chat", [
        {"authorization", "Bearer test-key"}
      ])
    end
  end
end
