defmodule Omni.Dialects.OpenAICompletionsIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Model, Provider, SSE, Tool}
  alias Omni.Providers.OpenRouter
  alias Omni.Dialects.OpenAICompletions

  @text_fixture "test/support/fixtures/sse/openrouter_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/openrouter_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/openrouter_thinking.sse"

  @model Model.new(
           id: "meta-llama/llama-3.1-8b-instruct",
           name: "Llama 3.1 8B Instruct",
           provider: OpenRouter,
           dialect: OpenAICompletions,
           max_output_tokens: 32768
         )

  @reasoning_model Model.new(
                     id: "deepseek/deepseek-r1",
                     name: "DeepSeek R1",
                     provider: OpenRouter,
                     dialect: OpenAICompletions,
                     max_output_tokens: 32768,
                     reasoning: true
                   )

  describe "text streaming pipeline" do
    setup do
      Req.Test.stub(:openrouter_text, fn conn ->
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
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :openrouter_text}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(OpenRouter, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [:message, :block_delta, :block_delta, :message, :message]

      text_deltas =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :text}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: text}} -> text end)

      assert text_deltas == ["Hello", "!"]

      {:message, done} = Enum.find(deltas, &match?({:message, %{stop_reason: _}}, &1))
      assert done.stop_reason == :stop

      {:message, usage_msg} = List.last(deltas)
      assert usage_msg.usage["input_tokens"] == 10
      assert usage_msg.usage["output_tokens"] == 5
    end
  end

  describe "tool use streaming pipeline" do
    setup do
      Req.Test.stub(:openrouter_tool_use, fn conn ->
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
        req |> Req.merge(plug: {Req.Test, :openrouter_tool_use}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(OpenRouter, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [
               :message,
               :block_start,
               :block_delta,
               :block_delta,
               :message,
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

  describe "thinking streaming pipeline" do
    setup do
      Req.Test.stub(:openrouter_thinking, fn conn ->
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
        req |> Req.merge(plug: {Req.Test, :openrouter_thinking}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(OpenRouter, &1))
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

      {:message, usage_msg} = List.last(deltas)
      assert usage_msg.usage["input_tokens"] == 15
      assert usage_msg.usage["output_tokens"] == 25
    end
  end
end
