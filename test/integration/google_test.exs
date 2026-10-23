defmodule Integration.GoogleTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Content.{Text, Thinking}

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

    test "structured output request", %{model: model} do
      body = request_body(model, :structured_output)

      assert %{"responseMimeType" => "application/json", "responseSchema" => %{}} =
               body["generationConfig"]
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
end
