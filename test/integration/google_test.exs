defmodule Integration.GoogleTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.Capture

  @dir "test/support/fixtures/google"

  setup do
    {:ok, model} = Omni.get_model(:google, "gemini-3.8-flash")
    %{model: model}
  end

  describe "baseline" do
    test "text", %{model: model} do
      assert_text(model, "#{@dir}/text.sse")
    end

    test "thinking", %{model: model} do
      {resp, request} = assert_thinking(model, "#{@dir}/thinking.sse")

      assert request.body["generationConfig"]["thinkingConfig"] == %{
               "includeThoughts" => true,
               "thinkingLevel" => "low"
             }

      # Thought summaries, and the thought signature on the answer
      assert [%Thinking{text: "" <> _}, %Text{signature: "" <> _}] = resp.message.content
    end

    # Gemini reports thinking apart from `candidatesTokenCount`, billed as
    # output. Its `totalTokenCount` includes it, so the totals agree.
    test "thinking tokens count as output", %{model: model} do
      {resp, _request} = assert_thinking(model, "#{@dir}/thinking.sse")

      [total | _] =
        ~r/"totalTokenCount": ?(\d+)/
        |> Regex.scan(File.read!("#{@dir}/thinking.sse"), capture: :all_but_first)
        |> List.last()

      assert resp.usage.total_tokens == String.to_integer(total)
    end

    test "tool use", %{model: model} do
      assert_tool_use(model, "#{@dir}/tool_use.sse")
    end

    test "structured output", %{model: model} do
      {_resp, request} = assert_structured_output(model, "#{@dir}/structured_output.sse")

      assert %{"responseMimeType" => "application/json", "responseSchema" => %{}} =
               request.body["generationConfig"]
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/text.sse",
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent",
        [{"x-goog-api-key", "test-key"}]
      )
    end
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
  end

  describe "synthetic" do
    test "error event returns stream_error", %{model: model} do
      file = "test/support/fixtures/synthetic/google_error.sse"

      assert {:error, {:stream_error, "You've exceeded the rate limit."}} =
               Capture.replay(model, Context.new("Hello"), file)
    end

    # Gemini's implicit cache never reported a hit in testing, so this stands
    # in for a real cache case.
    test "cachedContentTokenCount comes out of input", %{model: model} do
      file = "test/support/fixtures/synthetic/google_cache.sse"
      assert {:ok, resp} = Capture.replay(model, Context.new("Hello"), file)

      assert resp.usage.input_tokens == 20
      assert resp.usage.output_tokens == 50
      assert resp.usage.cache_read_tokens == 80
    end
  end
end
