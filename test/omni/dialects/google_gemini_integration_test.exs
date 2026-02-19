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

      assert types == [:message, :block_delta, :message, :block_delta, :message]

      text_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :text}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert text_deltas == ["Hello", "!"]

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :stop
      assert done.usage["input_tokens"] == 5
      assert done.usage["output_tokens"] == 2
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

    test "build_request → Req.request → SSE.stream → parse_event produces tool use event" do
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

      types = Enum.map(deltas, &elem(&1, 0))

      # Google sends functionCall complete, so only block_start (no deltas)
      assert types == [:message, :block_start]

      {:block_start, start} = Enum.at(deltas, 1)
      assert start.name == "get_weather"
      assert start.input == %{"city" => "London"}
      assert is_binary(start.id)
      assert String.starts_with?(start.id, "google_fc_")
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
