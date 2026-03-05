defmodule Integration.LoopTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}
  alias Omni.Content.{Text, ToolUse, ToolResult}

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

  defp tool_with_handler do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
      handler: fn _input -> "72°F and sunny" end
    )
  end

  defp tool_without_handler do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}}
    )
  end

  defp context_with_tool(tool) do
    Context.new(
      messages: [Message.new("What is the weather in London?")],
      tools: [tool]
    )
  end

  # -- Auto-executes tools and returns final text --

  describe "auto-executes tools" do
    test "2-step loop returns final text response" do
      stub_sequence(:loop_auto, [@tool_use_fixture, @text_fixture])

      context = context_with_tool(tool_with_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :loop_auto}
               )

      assert resp.stop_reason == :stop
      assert [%Text{}] = resp.message.content

      # 3 messages: assistant (tool_use), user (tool_result), assistant (text)
      assert length(resp.messages) == 3

      assert [%Message{role: :assistant}, %Message{role: :user}, %Message{role: :assistant}] =
               resp.messages

      assert resp.message == List.last(resp.messages)

      # Tool result message
      [_, tool_result_msg, _] = resp.messages
      assert [%ToolResult{is_error: false}] = tool_result_msg.content
    end
  end

  # -- max_steps: 1 bypasses looping --

  describe "max_steps: 1" do
    test "bypasses looping, returns tool_use response" do
      stub_fixture(:loop_max1, @tool_use_fixture)

      context = context_with_tool(tool_with_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 max_steps: 1,
                 plug: {Req.Test, :loop_max1}
               )

      assert resp.stop_reason == :tool_use
      assert Enum.any?(resp.message.content, &match?(%ToolUse{}, &1))
      assert resp.messages == [resp.message]
    end
  end

  # -- :tool_result events emitted --

  describe "tool_result events" do
    test "emitted between loop steps" do
      stub_sequence(:loop_events, [@tool_use_fixture, @text_fixture])

      context = context_with_tool(tool_with_handler())
      test_pid = self()

      {:ok, sr} =
        Omni.stream_text(model(), context,
          api_key: "test-key",
          plug: {Req.Test, :loop_events}
        )

      {:ok, _resp} =
        sr
        |> StreamingResponse.on(:tool_result, fn event ->
          send(test_pid, {:tool_result, event})
        end)
        |> StreamingResponse.complete()

      assert_received {:tool_result, %ToolResult{name: "get_weather", is_error: false}}
    end
  end

  # -- max_steps caps the loop --

  describe "max_steps caps loop" do
    test "stops after max_steps rounds" do
      stub_fixture(:loop_capped, @tool_use_fixture)

      context = context_with_tool(tool_with_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 max_steps: 3,
                 plug: {Req.Test, :loop_capped}
               )

      assert resp.stop_reason == :tool_use

      # 3 assistant + 2 user = 5 messages
      assert length(resp.messages) == 5

      assistant_msgs = Enum.filter(resp.messages, &(&1.role == :assistant))
      user_msgs = Enum.filter(resp.messages, &(&1.role == :user))
      assert length(assistant_msgs) == 3
      assert length(user_msgs) == 2
    end
  end

  # -- Tool without handler breaks loop --

  describe "tool without handler" do
    test "returns tool_use response without looping" do
      stub_fixture(:loop_no_handler, @tool_use_fixture)

      context = context_with_tool(tool_without_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :loop_no_handler}
               )

      assert resp.stop_reason == :tool_use
      assert Enum.any?(resp.message.content, &match?(%ToolUse{}, &1))
      assert resp.messages == [resp.message]
    end
  end

  # -- Hallucinated tool name sends error to model --

  describe "hallucinated tool name" do
    test "sends error result and continues to second step" do
      stub_sequence(:loop_hallucinated, [@tool_use_fixture, @text_fixture])

      # Context has a different tool name than what the model calls
      different_tool =
        Omni.tool(
          name: "calculate",
          description: "Does math",
          input_schema: %{type: "object", properties: %{expr: %{type: "string"}}},
          handler: fn _input -> "42" end
        )

      context =
        Context.new(
          messages: [Message.new("What is the weather in London?")],
          tools: [different_tool]
        )

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :loop_hallucinated}
               )

      assert resp.stop_reason == :stop
      assert length(resp.messages) == 3

      # Tool result message has error
      [_, tool_result_msg, _] = resp.messages
      assert [%ToolResult{is_error: true}] = tool_result_msg.content
    end
  end

  # -- raw: true collects all request/response pairs --

  describe "raw: true" do
    test "collects request/response pairs from all steps" do
      stub_sequence(:loop_raw, [@tool_use_fixture, @text_fixture])

      context = context_with_tool(tool_with_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 raw: true,
                 plug: {Req.Test, :loop_raw}
               )

      assert is_list(resp.raw)
      assert length(resp.raw) == 2
      assert [{%Req.Request{}, %Req.Response{}}, {%Req.Request{}, %Req.Response{}}] = resp.raw
    end
  end

  # -- Usage aggregation --

  describe "usage aggregation" do
    test "aggregates usage across multiple steps" do
      stub_sequence(:loop_usage, [@tool_use_fixture, @text_fixture])

      context = context_with_tool(tool_with_handler())

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :loop_usage}
               )

      # Both fixtures report usage; aggregated total should exceed either single step
      assert resp.usage.total_tokens > 0
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
    end
  end

  # -- No tools in context --

  describe "no tools in context" do
    test "single-step, messages is [message]" do
      stub_fixture(:loop_no_tools, @text_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku.",
                 api_key: "test-key",
                 plug: {Req.Test, :loop_no_tools}
               )

      assert resp.stop_reason == :stop
      assert resp.messages == [resp.message]
    end
  end
end
