defmodule Omni.LoopTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Loop, Message, StreamingResponse}

  @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"
  @text_fixture "test/support/fixtures/sse/anthropic_text.sse"

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_sequence(stub_name, fixtures) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub_name, fn conn ->
      call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      fixture = Enum.at(fixtures, call_num, List.last(fixtures))
      body = File.read!(fixture)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
    model
  end

  defp opts(plug_name), do: [api_key: "test-key", plug: {Req.Test, plug_name}]

  # -- Single step (no tools) --

  describe "single step — no tools" do
    test "returns response with messages: [message]" do
      stub_fixture(:unit_no_tools, @text_fixture)

      context = Context.new("Hello")
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_no_tools), false, :infinity)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.stop_reason == :stop
      assert resp.messages == [resp.message]
      assert resp.raw == nil
    end
  end

  # -- Tool execution result formatting --

  describe "tool execution" do
    test "binary result is passed through" do
      stub_sequence(:unit_binary_result, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny and warm" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      test_pid = self()

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_binary_result), false, :infinity)

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn event ->
          send(test_pid, {:result, event.output})
        end)
        |> StreamingResponse.complete()

      assert_received {:result, "sunny and warm"}
    end

    test "non-binary result is inspected" do
      stub_sequence(:unit_inspect_result, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> %{temp: 72, unit: "F"} end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      test_pid = self()

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_inspect_result), false, :infinity)

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn event ->
          send(test_pid, {:result, event.output})
        end)
        |> StreamingResponse.complete()

      assert_received {:result, output}
      assert output =~ "temp"
      assert output =~ "72"
    end

    test "handler error produces error tool result" do
      stub_sequence(:unit_handler_error, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> raise "connection timeout" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      test_pid = self()

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_handler_error), false, :infinity)

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn event ->
          send(test_pid, {:result, event})
        end)
        |> StreamingResponse.complete()

      assert_received {:result, %{is_error: true, output: output}}
      assert output =~ "connection timeout"
    end
  end

  # -- Cancel across steps --

  describe "cancel" do
    test "cancel works on the outer streaming response" do
      stub_fixture(:unit_cancel, @text_fixture)

      context = Context.new("Hello")
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_cancel), false, :infinity)

      assert :ok = StreamingResponse.cancel(sr)
    end
  end

  # -- Usage aggregation --

  describe "usage aggregation" do
    test "sums usage across steps" do
      stub_sequence(:unit_usage_agg, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_usage_agg), false, :infinity)
      {:ok, resp} = StreamingResponse.complete(sr)

      # Both fixtures have usage data, aggregated total should exceed either alone
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0

      # Verify aggregation: get single-step usage for comparison
      stub_fixture(:unit_usage_single, @tool_use_fixture)
      context2 = Context.new(messages: [Message.new("Weather?")], tools: [tool])

      {:ok, sr2} =
        Loop.stream(model(), context2, opts(:unit_usage_single), false, 1)

      {:ok, single_resp} = StreamingResponse.complete(sr2)

      assert resp.usage.total_tokens > single_resp.usage.total_tokens
    end
  end

  # -- text_stream works across loop steps --

  describe "text_stream" do
    test "yields text deltas from all steps" do
      stub_sequence(:unit_text_stream, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_text_stream), false, :infinity)

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      # Should have text deltas from both steps
      # Step 1 (tool_use fixture) has text "I'll get the current weather in London for you."
      # Step 2 (text fixture) has a haiku
      assert length(texts) > 0
      full_text = Enum.join(texts)
      assert byte_size(full_text) > 0
    end
  end

  # -- on/3 handlers fire across steps --

  describe "on/3 across steps" do
    test "done handler fires once at the end" do
      stub_sequence(:unit_on_done, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      test_pid = self()

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_on_done), false, :infinity)

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:done, fn event ->
          send(test_pid, {:done, event.stop_reason})
        end)
        |> StreamingResponse.complete()

      assert_received {:done, :stop}
      refute_received {:done, _}
    end
  end
end
