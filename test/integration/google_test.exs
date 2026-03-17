defmodule Integration.GoogleTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}
  alias Omni.Content.{Text, Thinking, ToolUse}

  @text_fixture "test/support/fixtures/sse/google_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/google_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/google_thinking.sse"

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:google, "gemini-2.5-flash")
    model
  end

  describe "generate_text/3 — text" do
    test "returns a text response" do
      stub_fixture(:int_google_text, @text_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku about why the sky is blue.",
                 api_key: "test-key",
                 plug: {Req.Test, :int_google_text}
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
      stub_fixture(:int_google_tool, @tool_use_fixture)

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
                 plug: {Req.Test, :int_google_tool}
               )

      assert resp.stop_reason == :tool_use
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert tool_use = Enum.find(resp.message.content, &match?(%ToolUse{}, &1))
      assert is_binary(tool_use.name) and tool_use.name == "get_weather"
      assert is_map(tool_use.input)
    end
  end

  describe "generate_text/3 — thinking" do
    test "returns thinking and text content" do
      stub_fixture(:int_google_thinking, @thinking_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "How many R's are in strawberry?",
                 api_key: "test-key",
                 thinking: :high,
                 plug: {Req.Test, :int_google_thinking}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
    end
  end

  describe "generate_text/3 — mid-stream error" do
    test "error event returns stream_error" do
      stub_fixture(:int_google_error, "test/support/fixtures/synthetic/google_error.sse")

      assert {:error, {:stream_error, "You've exceeded the rate limit."}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :int_google_error}
               )
    end
  end

  describe "stream_text/3 — text streaming" do
    test "streams text and completes with full response" do
      stub_fixture(:int_google_stream, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about why the sky is blue.",
          api_key: "test-key",
          plug: {Req.Test, :int_google_stream}
        )

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end

    test "complete/1 returns a full response" do
      stub_fixture(:int_google_complete, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about why the sky is blue.",
          api_key: "test-key",
          plug: {Req.Test, :int_google_complete}
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
