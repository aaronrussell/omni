defmodule Omni.Dialects.OpenAIResponsesIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Model, Provider, SSE, Tool}
  alias Omni.Providers.OpenAI
  alias Omni.Dialects.OpenAIResponses

  @text_fixture "test/support/fixtures/sse/openai_responses_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/openai_responses_tool_use.sse"

  @model Model.new(
           id: "gpt-4.1-nano",
           name: "GPT-4.1 nano",
           provider: OpenAI,
           dialect: OpenAIResponses,
           max_output_tokens: 32768
         )

  describe "text streaming pipeline" do
    setup do
      Req.Test.stub(:openai_responses_text, fn conn ->
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
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :openai_responses_text}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(OpenAI, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [:message, :block_delta, :block_delta, :message]

      text_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :text}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert text_deltas == ["Hello", "!"]

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :stop
      assert done.usage["input_tokens"] == 10
      assert done.usage["output_tokens"] == 5
    end
  end

  describe "tool use streaming pipeline" do
    setup do
      Req.Test.stub(:openai_responses_tool_use, fn conn ->
        body = File.read!(@tool_use_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok
    end

    test "build_request → Req.request → SSE.stream → parse_event produces tool use deltas" do
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

      {:ok, resp} =
        req |> Req.merge(plug: {Req.Test, :openai_responses_tool_use}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(OpenAI, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [
               :message,
               :block_start,
               :block_delta,
               :block_delta,
               :message
             ]

      {:block_start, start} = Enum.at(deltas, 1)
      assert start.id == "call_abc123"
      assert start.name == "get_weather"

      json_fragments =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :tool_use}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: json}} -> json end)

      assert Enum.join(json_fragments) == "{\"city\":\"London\"}"

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :tool_use
    end
  end
end
