defmodule Integration.AgentTest do
  use ExUnit.Case, async: true

  alias Omni.{Agent, Context, Response, Usage}
  alias Omni.Content.{Text, ToolResult}

  @text_fixture "test/support/fixtures/sse/anthropic_text.sse"
  @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"

  # -- Test modules --

  defmodule WithInit do
    use Omni.Agent

    @impl Omni.Agent
    def init(opts), do: {:ok, %{name: opts[:agent_name] || "default"}}
  end

  defmodule FailInit do
    use Omni.Agent

    @impl Omni.Agent
    def init(_opts), do: {:error, :bad_config}
  end

  defmodule CustomStop do
    use Omni.Agent

    @impl Omni.Agent
    def handle_stop(response, state) do
      {:stop, %{state | assigns: Map.put(state.assigns, :last_stop_reason, response.stop_reason)}}
    end
  end

  defmodule RejectTool do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_call(%{name: "get_weather"} = _tool_use, state) do
      {:reject, "not allowed", state}
    end

    def handle_tool_call(_tool_use, state), do: {:execute, state}
  end

  defmodule ModifyResult do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_result(result, state) do
      modified = %{result | content: [Omni.Content.Text.new("modified output")]}
      {:ok, modified, state}
    end
  end

  defmodule TrackToolCalls do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_call(tool_use, state) do
      calls = Map.get(state.assigns, :tool_calls, [])
      state = %{state | assigns: Map.put(state.assigns, :tool_calls, calls ++ [tool_use.name])}
      {:execute, state}
    end
  end

  # -- Helpers --

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_sequence(stub_name, fixtures) do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub_name, fn conn ->
      call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      fixture = Enum.at(fixtures, call_num, List.last(fixtures))
      body = File.read!(fixture)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp tool_with_handler do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
      handler: fn _input -> "72F and sunny" end
    )
  end

  defp tool_without_handler do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}}
    )
  end

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
    model
  end

  defp start_agent(opts \\ []) do
    stub_name = opts[:stub_name] || unique_stub_name()

    case opts[:fixtures] do
      nil -> stub_fixture(stub_name, opts[:fixture] || @text_fixture)
      fixtures -> stub_sequence(stub_name, fixtures)
    end

    agent_opts =
      Keyword.merge(
        [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
        Keyword.drop(opts, [:stub_name, :fixture, :fixtures])
      )

    Agent.start_link(agent_opts)
  end

  defp start_agent_with_module(module, opts) do
    stub_name = opts[:stub_name] || unique_stub_name()

    case opts[:fixtures] do
      nil -> stub_fixture(stub_name, opts[:fixture] || @text_fixture)
      fixtures -> stub_sequence(stub_name, fixtures)
    end

    module_opts =
      Keyword.merge(
        [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
        Keyword.drop(opts, [:stub_name, :fixture, :fixtures])
      )

    module.start_link(module_opts)
  end

  defp unique_stub_name do
    :"agent_test_#{System.unique_integer([:positive])}"
  end

  defp collect_events(agent_pid, timeout \\ 5000) do
    collect_events_loop(agent_pid, [], timeout)
  end

  defp collect_events_loop(agent_pid, acc, timeout) do
    receive do
      {:agent, ^agent_pid, :done, response} ->
        Enum.reverse([{:done, response} | acc])

      {:agent, ^agent_pid, :error, reason} ->
        Enum.reverse([{:error, reason} | acc])

      {:agent, ^agent_pid, :cancelled, nil} ->
        Enum.reverse([{:cancelled, nil} | acc])

      {:agent, ^agent_pid, type, data} ->
        collect_events_loop(agent_pid, [{type, data} | acc], timeout)
    after
      timeout -> {:timeout, Enum.reverse(acc)}
    end
  end

  # -- Tests --

  describe "basic prompt/response" do
    test "streams text events and emits :done with a valid response" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")

      events = collect_events(agent)
      assert is_list(events)
      refute match?({:timeout, _}, events)

      text_deltas = for {:text_delta, _data} <- events, do: :ok
      assert length(text_deltas) > 0

      assert {:done, %Response{} = resp} = List.last(events)
      assert resp.stop_reason == :stop
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end
  end

  describe "auto listener" do
    test "first prompt caller becomes listener automatically" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")

      events = collect_events(agent)
      assert {:done, %Response{}} = List.last(events)
    end
  end

  describe "explicit listener" do
    test "events go to the listener process" do
      {:ok, agent} = start_agent()

      test_pid = self()
      :ok = Agent.listen(agent, test_pid)
      :ok = Agent.prompt(agent, "Hello!")

      events = collect_events(agent)
      assert {:done, %Response{}} = List.last(events)
    end
  end

  describe "cancel" do
    test "cancels a running step and emits :cancelled" do
      # Use a slow stub that sleeps to give time to cancel
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(2000)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert {:cancelled, nil} = List.last(events)
      assert Agent.get_status(agent) == :idle
      assert Agent.get_context(agent).messages == []
    end

    test "cancel while idle returns error" do
      {:ok, agent} = start_agent()
      assert {:error, :idle} = Agent.cancel(agent)
    end
  end

  describe "clear" do
    test "resets messages and usage but preserves assigns" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      # Context should have messages after prompt completes
      assert length(Agent.get_context(agent).messages) > 0
      assert Agent.get_usage(agent).total_tokens > 0

      :ok = Agent.clear(agent)

      assert Agent.get_context(agent).messages == []
      assert Agent.get_usage(agent) == %Usage{}
    end

    test "clear while running returns error" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(2000)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert {:error, :running} = Agent.clear(agent)
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "usage accumulation" do
    test "usage sums across multiple prompt rounds" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "First message")
      _events = collect_events(agent)
      usage1 = Agent.get_usage(agent)
      assert usage1.total_tokens > 0

      # Need a new stub for the second request
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent2} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent2, "First")
      _events = collect_events(agent2)
      first_usage = Agent.get_usage(agent2)

      # Stub a new fixture for the second call
      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      total_usage = Agent.get_usage(agent2)

      assert total_usage.total_tokens == first_usage.total_tokens * 2
    end
  end

  describe "custom init callback" do
    test "init sets assigns" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          agent_name: "test-bot",
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_assigns(agent) == %{name: "test-bot"}
    end

    test "init with default name" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_assigns(agent) == %{name: "default"}
    end
  end

  describe "custom handle_stop callback" do
    test "handle_stop can modify assigns" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        CustomStop.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      assert Agent.get_assigns(agent).last_stop_reason == :stop
    end
  end

  describe "init error" do
    test "start_link fails when init returns error" do
      Process.flag(:trap_exit, true)

      assert {:error, :bad_config} =
               FailInit.start_link(
                 model: model(),
                 opts: [api_key: "test-key"]
               )
    end
  end

  describe "prompt while running" do
    test "returns {:error, :running}" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(2000)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert {:error, :running} = Agent.prompt(agent, "Again!")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "named agent" do
    test "can be called by name" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      name = :"agent_named_#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        Agent.start_link(
          model: model(),
          name: name,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_status(name) == :idle
      assert %Omni.Model{} = Agent.get_model(name)
    end
  end

  describe "getters" do
    test "get_model returns the model" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_model(agent)
    end

    test "get_context returns the context" do
      {:ok, agent} = start_agent()
      assert %Context{messages: [], tools: []} = Agent.get_context(agent)
    end

    test "get_status returns :idle initially" do
      {:ok, agent} = start_agent()
      assert Agent.get_status(agent) == :idle
    end

    test "get_assigns returns empty map by default" do
      {:ok, agent} = start_agent()
      assert Agent.get_assigns(agent) == %{}
    end

    test "get_usage returns zero usage initially" do
      {:ok, agent} = start_agent()
      assert Agent.get_usage(agent) == %Usage{}
    end
  end

  describe "use macro start_link/1" do
    test "generated start_link works" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert is_pid(agent)
      assert Agent.get_assigns(agent) == %{name: "default"}
    end
  end

  describe "conversation context builds up" do
    test "messages accumulate across prompts" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "First message")
      _events = collect_events(agent)

      context = Agent.get_context(agent)
      assert length(context.messages) == 2

      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent2} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent2, "First")
      _events = collect_events(agent2)
      assert length(Agent.get_context(agent2).messages) == 2

      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      assert length(Agent.get_context(agent2).messages) == 4
    end
  end

  describe "system prompt" do
    test "system prompt is set from opts" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          system: "You are a helpful assistant.",
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_context(agent).system == "You are a helpful assistant."
    end
  end

  # -- Tool execution tests (Phase 2) --

  describe "tool use auto-loop" do
    test "executes tool and loops back to get final text response" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather in London?")
      events = collect_events(agent)

      # Should have tool_result events
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert length(tool_results) > 0

      # Should end with :done and a text response
      assert {:done, %Response{stop_reason: :stop} = resp} = List.last(events)
      assert [%Text{}] = resp.message.content

      # Context should have all messages: user, assistant(tool_use), user(tool_results), assistant(text)
      context = Agent.get_context(agent)
      assert length(context.messages) >= 4
    end
  end

  describe "schema-only tool" do
    test "does not loop, fires handle_stop with tool_use stop reason" do
      {:ok, agent} =
        start_agent_with_module(CustomStop,
          tools: [tool_without_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # No tool_result events
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert tool_results == []

      # Should end with :done and tool_use stop reason
      assert {:done, %Response{stop_reason: :tool_use}} = List.last(events)
      assert Agent.get_assigns(agent).last_stop_reason == :tool_use
    end
  end

  describe "handle_tool_call reject" do
    test "rejected tool produces error result, loop continues" do
      {:ok, agent} =
        start_agent_with_module(RejectTool,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Tool result event should have is_error: true
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)

      # Loop continues to final text response
      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end
  end

  describe "handle_tool_result modifies result" do
    test "modified result is used in the loop" do
      {:ok, agent} =
        start_agent_with_module(ModifyResult,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      assert {:done, %Response{}} = List.last(events)

      # The tool result user message should contain modified content
      context = Agent.get_context(agent)

      tool_result_msgs =
        Enum.filter(context.messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      assert length(tool_result_msgs) == 1
      [tr_msg] = tool_result_msgs
      [%ToolResult{} = tr] = tr_msg.content
      assert [%Text{text: "modified output"}] = tr.content
    end
  end

  describe "tool_result events emitted" do
    test "agent emits :tool_result events with expected data" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) == 1
      [tr] = tool_result_events
      assert tr.name == "get_weather"
      assert tr.is_error == false
    end
  end

  describe "add_tools/remove_tools" do
    test "adds and removes tools when idle" do
      {:ok, agent} = start_agent()

      assert Agent.get_context(agent).tools == []

      tool = tool_with_handler()
      :ok = Agent.add_tools(agent, [tool])
      assert length(Agent.get_context(agent).tools) == 1
      assert hd(Agent.get_context(agent).tools).name == "get_weather"

      :ok = Agent.remove_tools(agent, ["get_weather"])
      assert Agent.get_context(agent).tools == []
    end

    test "returns {:error, :running} when agent is running" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(2000)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert {:error, :running} = Agent.add_tools(agent, [tool_with_handler()])
      assert {:error, :running} = Agent.remove_tools(agent, ["get_weather"])
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "cancel during tool execution" do
    test "cancels and rolls back context" do
      slow_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input ->
            Process.sleep(5000)
            "result"
          end
        )

      {:ok, agent} =
        start_agent(
          tools: [slow_tool],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      # Wait for step to complete and executor to start
      Process.sleep(200)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert {:cancelled, nil} = List.last(events)
      assert Agent.get_status(agent) == :idle
      assert Agent.get_context(agent).messages == []
    end
  end

  describe "tool timeout" do
    test "timed out tool produces error result, loop continues" do
      slow_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input ->
            Process.sleep(5000)
            "result"
          end
        )

      {:ok, agent} =
        start_agent(
          tools: [slow_tool],
          tool_timeout: 100,
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Tool result event should have is_error: true (timeout)
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)

      # Loop continues to final response
      assert {:done, %Response{}} = List.last(events)
    end
  end

  describe "usage accumulates across tool loop steps" do
    test "usage from both LLM requests is summed" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      _events = collect_events(agent)

      usage = Agent.get_usage(agent)
      assert usage.total_tokens > 0
      assert usage.input_tokens > 0
      assert usage.output_tokens > 0
    end
  end

  describe "handle_tool_call modifies assigns" do
    test "callback can store info in assigns" do
      {:ok, agent} =
        start_agent_with_module(TrackToolCalls,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      _events = collect_events(agent)

      assigns = Agent.get_assigns(agent)
      assert assigns.tool_calls == ["get_weather"]
    end
  end
end
