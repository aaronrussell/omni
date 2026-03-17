defmodule Integration.OpenAITest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}
  alias Omni.Content.{Text, Thinking, ToolUse}

  @text_fixture "test/support/fixtures/sse/openai_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/openai_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/openai_thinking.sse"

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:openai, "gpt-4.1-mini")
    model
  end

  defp reasoning_model do
    {:ok, model} = Omni.get_model(:openai, "o4-mini")
    model
  end

  describe "generate_text/3 — text" do
    test "returns a text response" do
      stub_fixture(:int_openai_text, @text_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku about why the sky is blue.",
                 api_key: "test-key",
                 plug: {Req.Test, :int_openai_text}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert %Omni.Model{} = resp.model
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end
  end

  describe "generate_text/3 — tool use" do
    test "returns a tool use response" do
      stub_fixture(:int_openai_tool, @tool_use_fixture)

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context =
        Context.new(
          messages: [Message.new("What is the weather in London?")],
          tools: [tool]
        )

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :int_openai_tool}
               )

      assert resp.stop_reason == :tool_use
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert tool_use = Enum.find(resp.message.content, &match?(%ToolUse{}, &1))
      assert is_binary(tool_use.name) and tool_use.name == "get_weather"
      assert is_map(tool_use.input)
      assert is_binary(tool_use.id)
    end
  end

  describe "generate_text/3 — thinking" do
    test "returns thinking and text content" do
      stub_fixture(:int_openai_thinking, @thinking_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(reasoning_model(), "How many R's are in strawberry?",
                 api_key: "test-key",
                 thinking: :high,
                 plug: {Req.Test, :int_openai_thinking}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
    end
  end

  describe "generate_text/3 — mid-stream error" do
    test "response.failed event returns stream_error" do
      stub_fixture(
        :int_openai_err_failed,
        "test/support/fixtures/synthetic/openai_responses_failed.sse"
      )

      assert {:error, {:stream_error, "The model failed to generate a response."}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :int_openai_err_failed}
               )
    end

    test "error event returns stream_error" do
      stub_fixture(
        :int_openai_err_stream,
        "test/support/fixtures/synthetic/openai_responses_stream_error.sse"
      )

      assert {:error, {:stream_error, "An error occurred during streaming."}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :int_openai_err_stream}
               )
    end
  end

  describe "stream_text/3 — text streaming" do
    test "streams text and completes with full response" do
      stub_fixture(:int_openai_stream, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about why the sky is blue.",
          api_key: "test-key",
          plug: {Req.Test, :int_openai_stream}
        )

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end

    test "complete/1 returns a full response" do
      stub_fixture(:int_openai_complete, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about why the sky is blue.",
          api_key: "test-key",
          plug: {Req.Test, :int_openai_complete}
        )

      assert {:ok, %Response{} = resp} = StreamingResponse.complete(sr)
      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert byte_size(text) > 0
    end
  end
end
