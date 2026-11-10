defmodule Integration.Dialects.GoogleGenerateContentTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, ToolUse}
  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API. Provider quirks live in the provider tests.
  @dir "test/support/fixtures/dialects/google_generate_content"

  setup do
    %{model: Cases.reference(:google_generate_content)}
  end

  describe "cases" do
    # With thinking on, the first function call carries a thought signature,
    # which must go back with the tool results.
    test "parallel tool calls replay the thought signature", %{model: model} do
      {context, opts} = request(:kitchen_sink)

      assert {:ok, resp1} = Capture.replay(model, context, "#{@dir}/tools_1.sse", opts)
      assert resp1.stop_reason == :tool_use
      assert [%ToolUse{signature: "" <> _ = signature} | rest] = resp1.message.content
      assert length(rest) == 3 and Enum.all?(rest, &match?(%ToolUse{signature: nil}, &1))
      assert_received {:replay_request, _}

      turn2 = tool_round(context, resp1)
      assert {:ok, resp2} = Capture.replay(model, turn2, "#{@dir}/tools_2.sse", opts)
      assert_received {:replay_request, %{body: body}}

      assert [_question, %{"role" => "model", "parts" => [call | _]}, %{"parts" => results}] =
               body["contents"]

      assert %{"functionCall" => %{"name" => "get_time"}, "thoughtSignature" => ^signature} = call
      assert length(results) == 4

      assert resp2.stop_reason == :stop
      assert [%Text{text: "" <> _}] = resp2.message.content
    end

    # Thinking spent the whole budget: no answer text, only the signature, and
    # no `candidatesTokenCount`. The thinking still counts as output.
    test "MAX_TOKENS with only thinking is :length", %{model: model} do
      {context, opts} = Cases.request(:length)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/length.sse", opts)

      assert resp.stop_reason == :length
      assert [%Text{text: "", signature: "" <> _}] = resp.message.content
      assert resp.usage.output_tokens > 0
      assert resp.usage.total_tokens == total_tokens("#{@dir}/length.sse")
    end
  end

  describe "synthetic" do
    test "error event returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "You've exceeded the rate limit."}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/error.sse")
    end

    # Gemini's implicit cache never reported a hit in testing, so this stands
    # in for a real cache case.
    test "cachedContentTokenCount comes out of input", %{model: model} do
      assert {:ok, resp} = Capture.replay(model, Context.new("Hello"), "#{@dir}/cache.sse")

      assert resp.usage.input_tokens == 20
      assert resp.usage.output_tokens == 50
      assert resp.usage.cache_read_tokens == 80
    end
  end

  defp total_tokens(file) do
    [total] = Regex.run(~r/"totalTokenCount": ?(\d+)/, File.read!(file), capture: :all_but_first)
    String.to_integer(total)
  end
end
