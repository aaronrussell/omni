defmodule Omni.Dialects.AnthropicMessagesIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Model, Provider, SSE, Tool}
  alias Omni.Providers.Anthropic
  alias Omni.Dialects.AnthropicMessages

  @text_fixture "test/support/fixtures/sse/anthropic_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"
  @thinking_fixture "test/support/fixtures/sse/anthropic_thinking.sse"

  @model Model.new(
           id: "claude-sonnet-4-20250514",
           name: "Claude Sonnet 4",
           provider: Anthropic,
           dialect: AnthropicMessages,
           max_output_tokens: 8192
         )

  @reasoning_model Model.new(
                     id: "claude-3.5-sonnet-20241022",
                     name: "Claude 3.5 Sonnet",
                     provider: Anthropic,
                     dialect: AnthropicMessages,
                     max_output_tokens: 8192,
                     reasoning: true
                   )

  describe "text streaming pipeline" do
    setup do
      Req.Test.stub(:anthropic_text, fn conn ->
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
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :anthropic_text}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Anthropic, &1))
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

      {:message, done} = List.last(deltas)
      assert done.stop_reason == :stop
    end
  end

  describe "tool use streaming pipeline" do
    setup do
      Req.Test.stub(:anthropic_tool_use, fn conn ->
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
      {:ok, resp} = req |> Req.merge(plug: {Req.Test, :anthropic_tool_use}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Anthropic, &1))
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert :message in types
      assert :block_start in types

      tool_starts =
        Enum.filter(deltas, &match?({:block_start, %{type: :tool_use}}, &1))

      assert length(tool_starts) > 0

      {:block_start, start} = hd(tool_starts)
      assert is_binary(start.id) and start.id != ""
      assert is_binary(start.name) and start.name != ""

      json_fragments =
        deltas
        |> Enum.filter(&match?({:block_delta, %{type: :tool_use}}, &1))
        |> Enum.map(fn {:block_delta, %{delta: json}} -> json end)

      assert length(json_fragments) > 0
      assert {:ok, parsed} = JSON.decode(Enum.join(json_fragments))
      assert is_map(parsed)

      {:message, done} = List.last(deltas)
      assert done.stop_reason == :tool_use
    end
  end

  describe "thinking streaming pipeline" do
    setup do
      Req.Test.stub(:anthropic_thinking, fn conn ->
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
        req |> Req.merge(plug: {Req.Test, :anthropic_thinking}) |> Req.request()

      assert resp.status == 200

      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(Anthropic, &1))
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

      {:message, done} = List.last(deltas)
      assert done.stop_reason == :stop
    end
  end
end
