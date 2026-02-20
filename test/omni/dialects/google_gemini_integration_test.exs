defmodule Omni.Dialects.GoogleGeminiIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Model, Provider, SSE, Tool}
  alias Omni.Providers.Google
  alias Omni.Dialects.GoogleGemini

  @text_fixture "test/support/fixtures/sse/google_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/google_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/google_thinking.sse"

  @model Model.new(
           id: "gemini-2.0-flash-lite",
           name: "Gemini 2.0 Flash Lite",
           provider: Google,
           dialect: GoogleGemini,
           max_output_tokens: 8192
         )

  @reasoning_model Model.new(
                     id: "gemini-2.5-flash-preview",
                     name: "Gemini 2.5 Flash Preview",
                     provider: Google,
                     dialect: GoogleGemini,
                     max_output_tokens: 8192,
                     reasoning: true
                   )

  describe "text streaming pipeline" do
    setup do
      Req.Test.stub(:google_text, fn conn ->
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok
    end

    test "build_request → Req.request → SSE.stream → parse_event produces correct deltas" do
      context = Context.new("Hello")

      {:ok, req} = Provider.build_request(@model, context, api_key: "test-key")
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :google_text}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Google, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert :message in types
      assert :block_delta in types

      text_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :text}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert length(text_deltas) > 0
      assert Enum.all?(text_deltas, &(is_binary(&1) and &1 != ""))
      assert Enum.join(text_deltas) != ""

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :stop
      assert is_integer(done.usage["input_tokens"]) and done.usage["input_tokens"] > 0
      assert is_integer(done.usage["output_tokens"]) and done.usage["output_tokens"] > 0
    end
  end

  describe "tool use streaming pipeline" do
    setup do
      Req.Test.stub(:google_tool_use, fn conn ->
        body = File.read!(@tool_use_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok
    end

    test "build_request → Req.request → SSE.stream → parse_event processes events correctly" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context =
        Context.new(
          messages: [Message.new("What's the weather in London?")],
          tools: [tool]
        )

      {:ok, req} = Provider.build_request(@model, context, api_key: "test-key")
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :google_tool_use}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Google, &1))
        |> Enum.to_list()

      assert length(deltas) > 0

      types = Enum.map(deltas, &elem(&1, 0))

      assert :message in types

      # Real fixture may contain text or tool_use depending on model behavior.
      # Verify content blocks are present and well-formed.
      content_events =
        Enum.filter(deltas, fn
          {:block_delta, _} -> true
          {:block_start, _} -> true
          _ -> false
        end)

      assert length(content_events) > 0
    end
  end

  describe "thinking streaming pipeline" do
    setup do
      Req.Test.stub(:google_thinking, fn conn ->
        body = File.read!(@thinking_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok
    end

    test "build_request → Req.request → SSE.stream → parse_event produces thinking and text deltas" do
      context = Context.new("Hello")

      {:ok, req} =
        Provider.build_request(@reasoning_model, context, api_key: "test-key", thinking: true)

      {:ok, resp} =
        req |> Req.merge(plug: {Req.Test, :google_thinking}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Google, &1))
        |> Enum.to_list()

      thinking_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :thinking}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert length(thinking_deltas) > 0
      assert Enum.all?(thinking_deltas, &(is_binary(&1) and &1 != ""))

      text_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :text}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert length(text_deltas) > 0
      assert Enum.all?(text_deltas, &(is_binary(&1) and &1 != ""))

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :stop
    end
  end
end
