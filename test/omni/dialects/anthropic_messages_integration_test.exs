defmodule Omni.Dialects.AnthropicMessagesIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Model, Provider, SSE, Tool}
  alias Omni.Providers.Anthropic
  alias Omni.Dialects.AnthropicMessages

  @text_fixture "test/support/fixtures/sse/anthropic_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"

  @model Model.new(
           id: "claude-sonnet-4-20250514",
           name: "Claude Sonnet 4",
           provider: Anthropic,
           dialect: AnthropicMessages,
           max_output_tokens: 8192
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
        |> Stream.map(&Provider.parse_event(Anthropic, &1))
        |> Stream.reject(&is_nil/1)
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [:start, :text_start, :text_delta, :text_delta, :content_block_end, :done]

      text_deltas =
        deltas
        |> Enum.filter(&match?({:text_delta, _}, &1))
        |> Enum.map(fn {:text_delta, %{delta: text}} -> text end)

      assert text_deltas == ["Hello", "!"]

      {:done, done} = List.last(deltas)
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
        |> Stream.map(&Provider.parse_event(Anthropic, &1))
        |> Stream.reject(&is_nil/1)
        |> Enum.to_list()

      types = Enum.map(deltas, &elem(&1, 0))

      assert types == [
               :start,
               :tool_use_start,
               :tool_use_delta,
               :tool_use_delta,
               :content_block_end,
               :done
             ]

      {:tool_use_start, start} = Enum.at(deltas, 1)
      assert start.id == "toolu_01ABC"
      assert start.name == "get_weather"

      json_fragments =
        deltas
        |> Enum.filter(&match?({:tool_use_delta, _}, &1))
        |> Enum.map(fn {:tool_use_delta, %{delta: json}} -> json end)

      assert Enum.join(json_fragments) == "{\"city\": \"London\"}"

      {:done, done} = List.last(deltas)
      assert done.stop_reason == :tool_use
    end
  end
end
