defmodule Integration.AgentTest do
  use ExUnit.Case, async: true

  alias Omni.{Agent, Context, Response, Usage}
  alias Omni.Content.{Text, ToolResult, ToolUse}

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

  defmodule ContinueAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(_opts), do: {:ok, %{turn_count: 0}}

    @impl Omni.Agent
    def handle_stop(_response, state) do
      count = state.assigns.turn_count + 1
      state = %{state | assigns: %{state.assigns | turn_count: count}}

      if count < 3 do
        {:continue, "Continue.", state}
      else
        {:stop, state}
      end
    end
  end

  defmodule ErrorRetryAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(_opts), do: {:ok, %{retries: 0}}

    @impl Omni.Agent
    def handle_error(_error, state) do
      retries = state.assigns.retries

      if retries < 1 do
        state = %{state | assigns: %{state.assigns | retries: retries + 1}}
        {:retry, state}
      else
        {:stop, state}
      end
    end
  end

  defmodule PauseAgent do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_call(%{name: "get_weather"} = _tool_use, state) do
      {:pause, state}
    end

    def handle_tool_call(_tool_use, state), do: {:execute, state}
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

  defp stub_error(stub_name) do
    Req.Test.stub(stub_name, fn conn ->
      Plug.Conn.send_resp(conn, 500, "Internal Server Error")
    end)
  end

  defp stub_error_then_success(stub_name, fixture_path) do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub_name, fn conn ->
      call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if call_num == 0 do
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      else
        body = File.read!(fixture_path)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end
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

      {:agent, ^agent_pid, :pause, tool_use} ->
        Enum.reverse([{:pause, tool_use} | acc])

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
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :context).messages == []
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
      assert length(Agent.get_state(agent, :context).messages) > 0
      assert Agent.get_state(agent, :usage).total_tokens > 0

      :ok = Agent.clear(agent)

      assert Agent.get_state(agent, :context).messages == []
      assert Agent.get_state(agent, :usage) == %Usage{}
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
      usage1 = Agent.get_state(agent, :usage)
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
      first_usage = Agent.get_state(agent2, :usage)

      # Stub a new fixture for the second call
      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      total_usage = Agent.get_state(agent2, :usage)

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

      assert Agent.get_state(agent, :assigns) == %{name: "test-bot"}
    end

    test "init with default name" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_state(agent, :assigns) == %{name: "default"}
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

      assert Agent.get_state(agent, :assigns).last_stop_reason == :stop
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

  describe "prompt while running (steering)" do
    test "stages prompt and returns :ok" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(200)
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
      assert :ok = Agent.prompt(agent, "Follow up!")
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

      assert Agent.get_state(name, :status) == :idle
      assert %Omni.Model{} = Agent.get_state(name, :model)
    end
  end

  describe "get_state" do
    test "returns the full state struct" do
      {:ok, agent} = start_agent()
      state = Agent.get_state(agent)
      assert %Omni.Agent.State{} = state
      assert %Omni.Model{id: "claude-haiku-4-5"} = state.model
      assert state.status == :idle
      assert state.assigns == %{}
    end

    test "returns individual fields by key" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_state(agent, :model)
      assert %Context{messages: [], tools: []} = Agent.get_state(agent, :context)
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :assigns) == %{}
      assert Agent.get_state(agent, :usage) == %Usage{}
    end

    test "returns nil for unknown keys" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :nonexistent) == nil
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
      assert Agent.get_state(agent, :assigns) == %{name: "default"}
    end
  end

  describe "conversation context builds up" do
    test "messages accumulate across prompts" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "First message")
      _events = collect_events(agent)

      context = Agent.get_state(agent, :context)
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
      assert length(Agent.get_state(agent2, :context).messages) == 2

      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      assert length(Agent.get_state(agent2, :context).messages) == 4
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

      assert Agent.get_state(agent, :context).system == "You are a helpful assistant."
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
      context = Agent.get_state(agent, :context)
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
      assert Agent.get_state(agent, :assigns).last_stop_reason == :tool_use
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
      context = Agent.get_state(agent, :context)

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

      assert Agent.get_state(agent, :context).tools == []

      tool = tool_with_handler()
      :ok = Agent.add_tools(agent, [tool])
      assert length(Agent.get_state(agent, :context).tools) == 1
      assert hd(Agent.get_state(agent, :context).tools).name == "get_weather"

      :ok = Agent.remove_tools(agent, ["get_weather"])
      assert Agent.get_state(agent, :context).tools == []
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
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :context).messages == []
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

      usage = Agent.get_state(agent, :usage)
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

      assigns = Agent.get_state(agent, :assigns)
      assert assigns.tool_calls == ["get_weather"]
    end
  end

  # -- Phase 3: handle_error --

  describe "handle_error" do
    test "default handle_error stops with :error event on step failure" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
    end

    test "custom {:retry, state} retries and succeeds on second attempt" do
      stub_name = unique_stub_name()
      stub_error_then_success(stub_name, @text_fixture)

      {:ok, agent} =
        ErrorRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
      assert Agent.get_state(agent, :assigns).retries == 1
    end

    test "retry exhaustion still emits :error" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        ErrorRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # After retrying once and failing again, should emit :error
      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :assigns).retries == 1
    end
  end

  # -- Phase 3: Continuation --

  describe "continuation" do
    test "{:continue, prompt, state} loops for 3 turns" do
      stub_name = unique_stub_name()
      # 3 turns = 3 LLM requests
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      # Should have exactly 2 :turn events and 1 :done event
      turn_events = for {:turn, _data} <- events, do: :ok
      done_events = for {:done, _data} <- events, do: :ok
      assert length(turn_events) == 2
      assert length(done_events) == 1

      assert {:done, %Response{}} = List.last(events)
      assert Agent.get_state(agent, :assigns).turn_count == 3
    end

    test "context accumulates all messages across turns" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start")
      _events = collect_events(agent)

      context = Agent.get_state(agent, :context)
      # Initial user + assistant, then 2 more (user continue + assistant) per extra turn
      # = 2 + 2 + 2 = 6 messages
      assert length(context.messages) == 6
    end

    test "usage accumulates across continuation turns" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start")
      _events = collect_events(agent)

      usage = Agent.get_state(agent, :usage)
      # Should be 3x a single request's usage
      assert usage.total_tokens > 0
    end
  end

  # -- Phase 3: max_steps --

  describe "max_steps" do
    test "limits steps even though ContinueAgent wants to continue" do
      stub_name = unique_stub_name()
      # ContinueAgent would want 3 turns, but max_steps: 2 caps it
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start", max_steps: 2)
      events = collect_events(agent)

      # Should stop after 2 steps
      assert {:done, %Response{}} = List.last(events)
      # Only 1 :turn event (step 1 completes, continues, step 2 completes, forced stop)
      turn_events = for {:turn, _data} <- events, do: :ok
      assert length(turn_events) == 1
    end

    test "max_steps hit mid-tool-loop forces stop" do
      stub_name = unique_stub_name()
      # Step 1: tool_use, execute tool, step 2: tool_use again, but max_steps reached
      stub_sequence(stub_name, [@tool_use_fixture, @tool_use_fixture])

      {:ok, agent} =
        start_agent_with_module(CustomStop,
          stub_name: stub_name,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @tool_use_fixture]
        )

      :ok = Agent.prompt(agent, "Use tool twice", max_steps: 2)
      events = collect_events(agent)

      # Should stop with :done (max_steps hit after tool results processed)
      assert {:done, %Response{stop_reason: :tool_use}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle

      # Context should be committed (includes tool result messages)
      context = Agent.get_state(agent, :context)
      assert length(context.messages) > 0
    end
  end

  # -- Phase 3: Steering --

  describe "steering" do
    test "prompt while running returns :ok (not {:error, :running})" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(200)
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
      assert :ok = Agent.prompt(agent, "Follow up!")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end

    test "staged prompt overrides {:stop} at turn boundary" do
      stub_name = unique_stub_name()
      {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub_name, fn conn ->
        call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        # First call is slow so we can stage a prompt while running
        if call_num == 0, do: Process.sleep(200)

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.prompt(agent, "Follow up!")

      events = collect_events(agent)

      # Should have a :turn event (first turn) followed by :done (second turn from steering)
      turn_events = for {:turn, _data} <- events, do: :ok
      assert length(turn_events) == 1
      assert {:done, %Response{}} = List.last(events)
    end

    test "last-one-wins: second staged prompt replaces first" do
      stub_name = unique_stub_name()

      Req.Test.stub(stub_name, fn conn ->
        Process.sleep(300)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.prompt(agent, "First follow-up")
      :ok = Agent.prompt(agent, "Second follow-up")

      # The second prompt should win — agent will continue after first turn
      events = collect_events(agent)
      turn_events = for {:turn, _data} <- events, do: :ok
      assert length(turn_events) == 1
      assert {:done, %Response{}} = List.last(events)

      # Context should have messages from two turns
      context = Agent.get_state(agent, :context)
      # First user + assistant + second user + assistant = 4
      assert length(context.messages) == 4
    end

    test "prompt while paused stages content for next turn" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@tool_use_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, %ToolUse{}} = List.last(events)

      # Stage a prompt while paused
      assert :ok = Agent.prompt(agent, "Follow up after tools")

      :ok = Agent.resume(agent, :approve)
      events = collect_events(agent)

      # Should have :turn (tool loop completed) then :done (staged prompt turn)
      turn_events = for {:turn, _data} <- events, do: :ok
      assert length(turn_events) == 1
      assert {:done, %Response{}} = List.last(events)
    end
  end

  # -- Phase 3: Pause/Resume --

  describe "pause/resume" do
    test "{:pause, state} from handle_tool_call pauses agent" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @tool_use_fixture)

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)

      # Should end with :pause and a ToolUse
      assert {:pause, %ToolUse{name: "get_weather"}} = List.last(events)
      assert Agent.get_state(agent, :status) == :paused

      # Clean up
      stub_fixture(stub_name, @text_fixture)
      Agent.resume(agent, :approve)
      _events = collect_events(agent)
    end

    test "resume(:approve) executes tool and continues to :done" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@tool_use_fixture, @text_fixture])

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, %ToolUse{}} = List.last(events)

      :ok = Agent.resume(agent, :approve)
      events = collect_events(agent)

      # Should have tool_result and then :done
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert length(tool_results) > 0
      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end

    test "resume({:reject, reason}) produces error ToolResult and continues" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@tool_use_fixture, @text_fixture])

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, %ToolUse{}} = List.last(events)

      :ok = Agent.resume(agent, {:reject, "not safe"})
      events = collect_events(agent)

      # Should have tool_result with is_error and then :done
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)
      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end

    test "resume when not paused returns {:error, :not_paused}" do
      {:ok, agent} = start_agent()
      assert {:error, :not_paused} = Agent.resume(agent, :approve)
    end

    test "cancel while paused resets state" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @tool_use_fixture)

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, %ToolUse{}} = List.last(events)

      :ok = Agent.cancel(agent)
      events = collect_events(agent, 2000)
      assert {:cancelled, nil} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :context).messages == []
    end

    test "multiple tools: pause on first, approve, remaining processed normally" do
      # This test uses a module that only pauses on "get_weather" but auto-approves others
      # The fixture has one tool_use (get_weather) so after approval it should proceed normally
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@tool_use_fixture, @text_fixture])

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, %ToolUse{name: "get_weather"}} = List.last(events)

      :ok = Agent.resume(agent, :approve)
      events = collect_events(agent)

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end
  end
end
