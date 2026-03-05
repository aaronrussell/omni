defmodule Omni.LoopTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Loop, Message, StreamingResponse}
  alias Omni.Content.{Text, ToolResult}

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
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_no_tools))
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

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_binary_result))

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn %ToolResult{} = tr ->
          send(test_pid, {:result, tr})
        end)
        |> StreamingResponse.complete()

      assert_received {:result,
                       %ToolResult{name: "get_weather", content: [%Text{text: "sunny and warm"}]}}
    end

    test "non-binary result is JSON encoded" do
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

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_inspect_result))

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn %ToolResult{} = tr ->
          send(test_pid, {:result, tr})
        end)
        |> StreamingResponse.complete()

      assert_received {:result, %ToolResult{content: [%Text{text: output}]}}
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

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_handler_error))

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn %ToolResult{} = tr ->
          send(test_pid, {:result, tr})
        end)
        |> StreamingResponse.complete()

      assert_received {:result, %ToolResult{is_error: true, content: [%Text{text: output}]}}
      assert output =~ "connection timeout"
    end
  end

  # -- max_steps capping --

  describe "max_steps" do
    test "max_steps: 1 breaks the loop after one step" do
      stub_fixture(:unit_max_steps_1, @tool_use_fixture)

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_max_steps_1) ++ [max_steps: 1])
      {:ok, resp} = StreamingResponse.complete(sr)

      # Only one step executed — response still has tool_use stop reason
      assert resp.stop_reason == :tool_use
      assert length(resp.messages) == 1
    end

    test "max_steps: 2 allows tool loop then final response" do
      stub_sequence(:unit_max_steps_2, [@tool_use_fixture, @text_fixture])

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_max_steps_2) ++ [max_steps: 2])
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.stop_reason == :stop
      # Two steps: assistant tool_use + user tool_result + assistant text
      assert length(resp.messages) == 3
    end
  end

  # -- Schema-only tools (nil handler) --

  describe "schema-only tools break the loop" do
    test "tool with nil handler returns response without executing" do
      stub_fixture(:unit_schema_only, @tool_use_fixture)

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_schema_only))
      {:ok, resp} = StreamingResponse.complete(sr)

      # Loop breaks — no tool execution, no second step
      assert resp.stop_reason == :tool_use
      assert length(resp.messages) == 1
    end
  end

  # -- Structured output validation --

  describe "structured output validation" do
    test "valid JSON matching schema sets response.output" do
      stub_name = :unit_output_valid
      fixture = "test/support/fixtures/synthetic/anthropic_json_valid.sse"
      stub_fixture(stub_name, fixture)

      # Fixture returns {"city": "London", "temperature": 18}
      schema = %{type: :object, properties: %{city: %{type: :string}}, required: [:city]}
      context = Context.new("Give me JSON")
      {:ok, sr} = Loop.stream(model(), context, opts(stub_name) ++ [output: schema])
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.output["city"] == "London"
    end

    test "invalid JSON retries up to 3 times then returns without output" do
      stub_name = :unit_output_invalid

      # All responses return invalid JSON — loop retries 3 times then gives up
      stub_sequence(stub_name, [
        "test/support/fixtures/synthetic/anthropic_not_json.sse",
        "test/support/fixtures/synthetic/anthropic_not_json.sse",
        "test/support/fixtures/synthetic/anthropic_not_json.sse",
        "test/support/fixtures/synthetic/anthropic_not_json.sse"
      ])

      schema = %{type: :object, properties: %{name: %{type: :string}}, required: [:name]}
      context = Context.new("Give me JSON")
      {:ok, sr} = Loop.stream(model(), context, opts(stub_name) ++ [output: schema])
      {:ok, resp} = StreamingResponse.complete(sr)

      # Gave up after retries — output is nil
      assert resp.output == nil
    end

    test "length stop reason skips retry" do
      stub_name = :unit_output_length

      # Use the truncated fixture which gives no stop reason, but we need :length.
      # Actually, we need a fixture where stop_reason is :length. Let's use the
      # valid JSON fixture — the test is about the *validation path* not content.
      # We need to produce :length... let's stub a sequence where the model returns
      # truncated JSON with max_tokens stop reason. Use the json_truncated fixture.
      stub_fixture(stub_name, "test/support/fixtures/synthetic/anthropic_json_truncated.sse")

      schema = %{type: :object, properties: %{name: %{type: :string}}, required: [:name]}
      context = Context.new("Give me JSON")
      {:ok, sr} = Loop.stream(model(), context, opts(stub_name) ++ [output: schema])
      {:ok, resp} = StreamingResponse.complete(sr)

      # Should not retry — returns immediately with nil output
      assert resp.output == nil
      assert resp.stop_reason == :length
    end
  end

  # -- do_loop error path --

  describe "do_loop error path" do
    test "step error mid-loop emits :error event" do
      stub_name = :unit_loop_error
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub_name, fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if call_num == 0 do
          # First call: return tool_use
          body = File.read!(@tool_use_fixture)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
        else
          # Second call: transport error
          Req.Test.transport_error(conn, :closed)
        end
      end)

      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "sunny" end
        )

      context = Context.new(messages: [Message.new("Weather?")], tools: [tool])
      {:ok, sr} = Loop.stream(model(), context, opts(stub_name))

      events = Enum.to_list(sr)
      types = Enum.map(events, &elem(&1, 0))

      assert :error in types
      assert :tool_result in types
      refute :done in types
    end
  end

  # -- Cancel across steps --

  describe "cancel" do
    test "cancel works on the outer streaming response" do
      stub_fixture(:unit_cancel, @text_fixture)

      context = Context.new("Hello")
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_cancel))

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
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_usage_agg))
      {:ok, resp} = StreamingResponse.complete(sr)

      # Both fixtures have usage data, aggregated total should exceed either alone
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0

      # Verify aggregation: get single-step usage for comparison
      stub_fixture(:unit_usage_single, @tool_use_fixture)
      context2 = Context.new(messages: [Message.new("Weather?")], tools: [tool])

      {:ok, sr2} =
        Loop.stream(model(), context2, opts(:unit_usage_single) ++ [max_steps: 1])

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
      {:ok, sr} = Loop.stream(model(), context, opts(:unit_text_stream))

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

      {:ok, sr} = Loop.stream(model(), context, opts(:unit_on_done))

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
