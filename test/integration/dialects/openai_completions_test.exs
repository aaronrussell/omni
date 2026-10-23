defmodule Integration.Dialects.OpenAICompletionsTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  alias Omni.Context
  alias Omni.Content.ToolUse
  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API: OpenAI's own `/chat/completions`. Provider quirks live in the
  # provider tests.
  @dir "test/support/fixtures/dialects/openai_completions"

  setup do
    %{model: Cases.reference(:openai_completions)}
  end

  describe "cases" do
    # `prompt_tokens` includes the cached prefix on the wire.
    test "cache hit on turn 2", %{model: model} do
      assert_cache_hit(model, "#{@dir}/cache_1.sse", "#{@dir}/cache_2.sse")
    end

    # A `finish_reason: "length"` stop inside the arguments stays `:length`:
    # the call is incomplete and must not be run.
    test "finish_reason length mid tool call stays :length", %{model: model} do
      {context, opts} = Cases.request(:tool_length)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/tool_length.sse", opts)

      assert resp.stop_reason == :length
      assert [%ToolUse{name: "save_note", input: input}] = resp.message.content
      assert input == %{}
    end

    # The reference shape: one call per chunk, id and name first, arguments
    # after, each by its `index`. Recorded with thinking off: OpenAI rejects
    # tools with a `reasoning_effort` on `/chat/completions`.
    test "parallel tool calls", %{model: model} do
      {context, opts} = request(:kitchen_sink)
      opts = Keyword.put(opts, :thinking, false)
      assert {:ok, resp} = Capture.replay(model, context, "#{@dir}/tools_1.sse", opts)

      assert resp.stop_reason == :tool_use
      assert [_, _, _, _] = tool_uses = resp.message.content
      assert Enum.all?(tool_uses, &match?(%ToolUse{input: %{"city" => "" <> _}}, &1))
      assert tool_uses |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 4
    end
  end

  describe "synthetic" do
    # Completions has no error event: the error arrives as a chunk.
    test "error chunk returns stream_error", %{model: model} do
      assert {:error, {:stream_error, "The server had an error while processing your request."}} =
               Capture.replay(model, Context.new("Hello"), "#{@dir}/error.sse")
    end
  end
end
