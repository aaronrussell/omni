defmodule Integration.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Provider, Response, StreamingResponse}
  alias Omni.Content.{Text, Thinking, ToolUse}

  @text_fixture "test/support/fixtures/sse/openrouter_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/openrouter_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/openrouter_thinking.sse"

  setup_all do
    Provider.load([:openrouter])
    :ok
  end

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:openrouter, "openai/gpt-4.1-mini")
    model
  end

  defp reasoning_model do
    {:ok, model} = Omni.get_model(:openrouter, "openai/o4-mini")
    model
  end

  describe "generate_text/3 — text" do
    test "returns a text response" do
      stub_fixture(:int_openrouter_text, @text_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku about why the sky is blue.",
                 api_key: "test-key",
                 plug: {Req.Test, :int_openrouter_text}
               )

      assert resp.stop_reason == :stop
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end
  end

  describe "generate_text/3 — tool use" do
    test "returns a tool use response" do
      stub_fixture(:int_openrouter_tool, @tool_use_fixture)

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
                 plug: {Req.Test, :int_openrouter_tool}
               )

      assert resp.stop_reason == :tool_use
      assert tool_use = Enum.find(resp.message.content, &match?(%ToolUse{}, &1))
      assert is_binary(tool_use.name) and tool_use.name == "get_weather"
      assert is_map(tool_use.input)
    end
  end

  describe "generate_text/3 — thinking" do
    test "returns thinking and text content" do
      stub_fixture(:int_openrouter_thinking, @thinking_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(reasoning_model(), "How many R's are in strawberry?",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :int_openrouter_thinking}
               )

      assert resp.stop_reason == :stop

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
    end

    test "accumulates reasoning_details in message private" do
      stub_fixture(:int_openrouter_thinking_rd, @thinking_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(reasoning_model(), "How many R's are in strawberry?",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :int_openrouter_thinking_rd}
               )

      details = resp.message.private.reasoning_details
      assert is_list(details) and length(details) > 0

      types = Enum.map(details, & &1["type"])
      assert "reasoning.summary" in types
      assert "reasoning.encrypted" in types
    end
  end

  describe "reasoning_details outbound" do
    test "assistant message with reasoning_details in private encodes on wire" do
      test_pid = self()

      Req.Test.stub(:int_openrouter_outbound, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:captured_body, JSON.decode!(body)})

        sse_body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      reasoning_details = [
        %{"type" => "reasoning.summary", "summary" => "thinking about it"},
        %{"type" => "reasoning.encrypted", "data" => "encrypted_blob", "id" => "rs_123"}
      ]

      context =
        Context.new([
          Message.new(role: :user, content: "Hello"),
          Message.new(
            role: :assistant,
            content: "Hi there",
            private: %{reasoning_details: reasoning_details}
          ),
          Message.new(role: :user, content: "Follow up")
        ])

      assert {:ok, %Response{}} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :int_openrouter_outbound}
               )

      assert_received {:captured_body, captured}
      messages = captured["messages"]

      assistant_msg = Enum.find(messages, &(&1["role"] == "assistant"))
      assert assistant_msg["reasoning_details"] == reasoning_details

      user_msgs = Enum.filter(messages, &(&1["role"] == "user"))
      assert Enum.all?(user_msgs, &(not Map.has_key?(&1, "reasoning_details")))
    end
  end

  describe "stream_text/3 — text streaming" do
    test "text_stream yields non-empty binaries" do
      stub_fixture(:int_openrouter_stream, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about why the sky is blue.",
          api_key: "test-key",
          plug: {Req.Test, :int_openrouter_stream}
        )

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end
  end
end
