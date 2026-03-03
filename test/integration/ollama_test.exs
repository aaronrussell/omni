defmodule Integration.OllamaTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}
  alias Omni.Content.{Text, Thinking, ToolUse}

  @text_fixture "test/support/fixtures/ndjson/ollama_text.ndjson"
  @tool_use_fixture "test/support/fixtures/ndjson/ollama_tool_use.ndjson"
  @thinking_fixture "test/support/fixtures/ndjson/ollama_thinking.ndjson"

  setup_all do
    model =
      Omni.Model.new(
        id: "qwen3.5:4b",
        name: "qwen3.5:4b",
        provider: Omni.Providers.Ollama,
        dialect: Omni.Dialects.OllamaChat
      )

    Omni.Model.put(:ollama, model)
    :ok
  end

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:ollama, "qwen3.5:4b")
    model
  end

  describe "generate_text/3 — text" do
    test "returns a text response" do
      stub_fixture(:int_ollama_text, @text_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku about the sky.",
                 plug: {Req.Test, :int_ollama_text}
               )

      assert resp.stop_reason == :stop
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end
  end

  describe "generate_text/3 — tool use" do
    test "returns content with tool use" do
      stub_fixture(:int_ollama_tool, @tool_use_fixture)

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
               Omni.generate_text(model(), context, plug: {Req.Test, :int_ollama_tool})

      assert resp.stop_reason == :tool_use
      assert tool_use = Enum.find(resp.message.content, &match?(%ToolUse{}, &1))
      assert is_binary(tool_use.name) and tool_use.name == "get_weather"
      assert is_map(tool_use.input)
    end
  end

  describe "generate_text/3 — thinking" do
    test "returns thinking and text content" do
      stub_fixture(:int_ollama_thinking, @thinking_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "How many R's are in strawberry?",
                 thinking: true,
                 plug: {Req.Test, :int_ollama_thinking}
               )

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
    end
  end

  describe "stream_text/3 — text streaming" do
    test "text_stream yields non-empty binaries" do
      stub_fixture(:int_ollama_stream, @text_fixture)

      {:ok, sr} =
        Omni.stream_text(model(), "Write a haiku about the sky.",
          plug: {Req.Test, :int_ollama_stream}
        )

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end
  end
end
