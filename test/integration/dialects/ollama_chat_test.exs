defmodule Integration.Dialects.OllamaChatTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, ToolUse}
  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API: a local Ollama. Provider quirks live in the provider tests.
  @dir "test/support/fixtures/dialects/ollama_chat"

  setup do
    %{model: Cases.reference(:ollama_chat)}
  end

  describe "cases" do
    # `prompt_eval_count` includes the cached prefix, reported as
    # `prompt_eval_cached_count`.
    test "cache hit on turn 2", %{model: model} do
      assert_cache_hit(model, "#{@dir}/cache_1.ndjson", "#{@dir}/cache_2.ndjson")
    end

    test "done_reason length is :length", %{model: model} do
      {context, opts} = Cases.request(:length)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/length.ndjson", opts)

      assert resp.stop_reason == :length
      assert [%Text{text: "" <> _}] = resp.message.content
      assert resp.usage.output_tokens == 20
    end

    # Each call arrives whole, one chunk each, and the stream ends with
    # `done_reason: "stop"`: the tool calls make it `:tool_use`.
    test "parallel tool calls", %{model: model} do
      {context, opts} = request(:kitchen_sink)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/tools_1.ndjson", opts)

      assert resp.stop_reason == :tool_use
      tool_uses = Enum.filter(resp.message.content, &match?(%ToolUse{}, &1))
      assert length(tool_uses) == 4
      assert tool_uses |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 4
      assert Enum.all?(tool_uses, &match?(%{"city" => "" <> _}, &1.input))
    end

    # One `tool` message per result, carrying the call's id and name.
    test "tool round", %{model: model} do
      {context, opts} = request(:kitchen_sink)
      {:ok, resp1} = Capture.replay(model, context, "#{@dir}/tools_1.ndjson", opts)
      assert_received {:replay_request, _}

      turn2 = tool_round(context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/tools_2.ndjson", opts)
      assert_received {:replay_request, %{body: body}}

      assert [_question, %{"role" => "assistant", "tool_calls" => calls} | results] =
               body["messages"]

      assert length(results) == 4

      for {call, result} <- Enum.zip(calls, results) do
        assert %{"role" => "tool", "content" => "" <> _} = result
        assert result["tool_call_id"] == call["id"]
        assert result["tool_name"] == call["function"]["name"]
      end

      assert resp2.stop_reason == :stop
      assert [%Text{text: "" <> _} | _] = Enum.reject(resp2.message.content, &thinking?/1)
    end
  end

  defp thinking?(block), do: match?(%Omni.Content.Thinking{}, block)

  describe "synthetic" do
    test "error in the stream returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "an error was encountered while running the model"}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/error.ndjson")
    end
  end
end
