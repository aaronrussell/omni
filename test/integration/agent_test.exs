defmodule Integration.AgentTest do
  use ExUnit.Case, async: true

  alias Omni.{Agent, MessageTree, Response, Usage}
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
      {:stop, %{state | private: Map.put(state.private, :last_stop_reason, response.stop_reason)}}
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
      calls = Map.get(state.private, :tool_calls, [])
      state = %{state | private: Map.put(state.private, :tool_calls, calls ++ [tool_use.name])}
      {:execute, state}
    end
  end

  defmodule ContinueAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(_opts), do: {:ok, %{turn_count: 0}}

    @impl Omni.Agent
    def handle_stop(_response, state) do
      count = state.private.turn_count + 1
      state = %{state | private: %{state.private | turn_count: count}}

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
      retries = state.private.retries

      if retries < 1 do
        state = %{state | private: %{state.private | retries: retries + 1}}
        {:retry, state}
      else
        {:stop, state}
      end
    end
  end

  defmodule TerminateAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(opts), do: {:ok, opts[:private] || %{}}

    @impl Omni.Agent
    def terminate(reason, state) do
      if pid = state.private[:test_pid] do
        send(pid, {:terminated, reason})
      end
    end
  end

  defmodule CrashRetryAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(_opts), do: {:ok, %{retries: 0}}

    @impl Omni.Agent
    def handle_error({:step_crashed, _} = _error, state) do
      retries = state.private.retries

      if retries < 1 do
        {:retry, %{state | private: %{state.private | retries: retries + 1}}}
      else
        {:stop, state}
      end
    end

    def handle_error(_error, state), do: {:stop, state}
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

      {:agent, ^agent_pid, :error, response} ->
        Enum.reverse([{:error, response} | acc])

      {:agent, ^agent_pid, :cancelled, response} ->
        Enum.reverse([{:cancelled, response} | acc])

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
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # First prompt cancel: tree rolled back to empty (origin was nil)
      assert MessageTree.messages(Agent.get_state(agent, :tree)) == []
    end

    test "cancel while idle returns error" do
      {:ok, agent} = start_agent()
      assert {:error, :idle} = Agent.cancel(agent)
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

  describe "usage/1" do
    test "returns empty usage for fresh agent" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :usage) == %Usage{}
    end

    test "returns accumulated usage after prompts" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)
      assert Agent.get_state(agent, :usage).total_tokens > 0
    end
  end

  describe "navigate/2" do
    test "navigates to earlier turn" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)
      messages_after_first = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages_after_first) == 2

      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent, "Second")
      _events = collect_events(agent)
      messages_after_second = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages_after_second) == 4

      # Navigate back to end of first turn (node 1 = assistant response)
      :ok = Agent.navigate(agent, 1)
      tree = Agent.get_state(agent, :tree)
      assert length(MessageTree.messages(tree)) == 2
    end

    test "returns error for non-existent turn" do
      {:ok, agent} = start_agent()
      assert {:error, :not_found} = Agent.navigate(agent, 999)
    end

    test "returns error when running" do
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
      assert {:error, :not_idle} = Agent.navigate(agent, 0)
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end

    test "prompt after navigate branches from navigated turn" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      # Two turns: 0, 1
      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)
      :ok = Agent.prompt(agent, "Second")
      _events = collect_events(agent)

      # Navigate back to node 1 (end of first turn's assistant response)
      :ok = Agent.navigate(agent, 1)

      # Prompt creates a new branch from node 1
      :ok = Agent.prompt(agent, "Alternate second")
      _events = collect_events(agent)

      tree = Agent.get_state(agent, :tree)
      # Active path: [0, 1, new_user, new_asst]
      assert MessageTree.depth(tree) == 4
      # Node 1 should have two children: node 2 (original) and the new branch
      assert length(MessageTree.children(tree, 1)) == 2
    end
  end

  describe "set_state/2" do
    test "replaces system prompt" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :system) == nil
      :ok = Agent.set_state(agent, system: "Be helpful.")
      assert Agent.get_state(agent, :system) == "Be helpful."
    end

    test "replaces opts (full replacement, not merge)" do
      {:ok, agent} = start_agent()
      # Original opts include api_key and plug
      original_opts = Agent.get_state(agent, :opts)
      assert Keyword.has_key?(original_opts, :api_key)

      :ok = Agent.set_state(agent, opts: [temperature: 0.7])
      new_opts = Agent.get_state(agent, :opts)
      assert new_opts == [temperature: 0.7]
      refute Keyword.has_key?(new_opts, :api_key)
    end

    test "replaces meta (full replacement, not merge)" do
      {:ok, agent} = start_agent(meta: %{a: 1})
      assert Agent.get_state(agent, :meta) == %{a: 1}

      :ok = Agent.set_state(agent, meta: %{b: 2})
      assert Agent.get_state(agent, :meta) == %{b: 2}
    end

    test "replaces tools list" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :tools) == []

      tool = tool_with_handler()
      :ok = Agent.set_state(agent, tools: [tool])
      assert length(Agent.get_state(agent, :tools)) == 1
      assert hd(Agent.get_state(agent, :tools)).name == "get_weather"
    end

    test "replaces tree" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)
      assert length(MessageTree.messages(Agent.get_state(agent, :tree))) > 0

      new_tree = %MessageTree{}
      :ok = Agent.set_state(agent, tree: new_tree)
      assert MessageTree.messages(Agent.get_state(agent, :tree)) == []
    end

    test "rejects invalid keys" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :status}} = Agent.set_state(agent, status: :running)
    end

    test "atomic — bad model rejects all changes" do
      {:ok, agent} = start_agent()
      original_system = Agent.get_state(agent, :system)

      result = Agent.set_state(agent, model: {:anthropic, "nonexistent"}, system: "new")
      assert {:error, {:model_not_found, _}} = result
      # System should not have changed
      assert Agent.get_state(agent, :system) == original_system
    end

    test "returns error when running" do
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
      assert {:error, :running} = Agent.set_state(agent, system: "New")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "set_state/3" do
    test "replaces field with value" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :system, "New system")
      assert Agent.get_state(agent, :system) == "New system"
    end

    test "transforms field with function" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :opts, fn opts -> Keyword.put(opts, :temperature, 0.7) end)
      assert Keyword.get(Agent.get_state(agent, :opts), :temperature) == 0.7
    end

    test "rejects non-settable field" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :status}} = Agent.set_state(agent, :status, :running)
    end

    test "rejects non-settable field private" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :private}} = Agent.set_state(agent, :private, %{})
    end
  end

  describe "tree: at start_link" do
    test "accepts pre-built tree" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")
      {_, tree} = MessageTree.push(%MessageTree{}, user_msg)
      {_, tree} = MessageTree.push(tree, asst_msg)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          tree: tree,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert MessageTree.depth(Agent.get_state(agent, :tree)) == 2
    end

    test "prompt builds on existing tree" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")
      {_, tree} = MessageTree.push(%MessageTree{}, user_msg)
      {_, tree} = MessageTree.push(tree, asst_msg)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          tree: tree,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Follow up")
      _events = collect_events(agent)

      final_tree = Agent.get_state(agent, :tree)
      assert MessageTree.depth(final_tree) == 4

      # Third node's parent should be node 1 (the assistant msg)
      assert final_tree.nodes[2].parent_id == 1
    end
  end

  describe "Turn on events" do
    test "done event has response with correct data" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:done, %Response{} = resp} = List.last(events)
      assert length(resp.messages) > 0
      assert resp.usage.total_tokens > 0
    end

    test "second prompt produces response with messages" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)

      :ok = Agent.prompt(agent, "Second")
      events = collect_events(agent)

      assert {:done, %Response{}} = List.last(events)

      tree = Agent.get_state(agent, :tree)
      assert tree.nodes[1].parent_id == 0
    end
  end

  describe "custom init callback" do
    test "init sets private" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          agent_name: "test-bot",
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_state(agent, :private) == %{name: "test-bot"}
    end

    test "init with default name" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        WithInit.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      assert Agent.get_state(agent, :private) == %{name: "default"}
    end
  end

  describe "custom handle_stop callback" do
    test "handle_stop can modify private" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        CustomStop.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      assert Agent.get_state(agent, :private).last_stop_reason == :stop
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

    test "start_link fails when model is nil" do
      Process.flag(:trap_exit, true)

      assert {:error, :missing_model} =
               WithInit.start_link(opts: [api_key: "test-key"])
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
      assert state.private == %{}
      assert state.meta == %{}
    end

    test "returns individual fields by key" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_state(agent, :model)
      assert %MessageTree{} = Agent.get_state(agent, :tree)
      assert Agent.get_state(agent, :tools) == []
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :private) == %{}
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
      assert Agent.get_state(agent, :private) == %{name: "default"}
    end
  end

  describe "conversation context builds up" do
    test "messages accumulate across prompts" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "First message")
      _events = collect_events(agent)

      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages) == 2

      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent2} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent2, "First")
      _events = collect_events(agent2)
      assert length(MessageTree.messages(Agent.get_state(agent2, :tree))) == 2

      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      assert length(MessageTree.messages(Agent.get_state(agent2, :tree))) == 4
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

      assert Agent.get_state(agent, :system) == "You are a helpful assistant."
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

      # Tree should have all messages: user, assistant(tool_use), user(tool_results), assistant(text)
      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages) >= 4
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
      assert Agent.get_state(agent, :private).last_stop_reason == :tool_use
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
      messages = MessageTree.messages(Agent.get_state(agent, :tree))

      tool_result_msgs =
        Enum.filter(messages, fn msg ->
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
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # First prompt cancel: tree rolled back to empty (origin was nil)
      assert MessageTree.messages(Agent.get_state(agent, :tree)) == []
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

  describe "handle_tool_call modifies private" do
    test "callback can store info in private" do
      {:ok, agent} =
        start_agent_with_module(TrackToolCalls,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      _events = collect_events(agent)

      private = Agent.get_state(agent, :private)
      assert private.tool_calls == ["get_weather"]
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
      assert Agent.get_state(agent, :status) == :error
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
      assert Agent.get_state(agent, :private).retries == 1
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
      assert Agent.get_state(agent, :status) == :error
      assert Agent.get_state(agent, :private).retries == 1
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
      assert Agent.get_state(agent, :private).turn_count == 3
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

      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      # Initial user + assistant, then 2 more (user continue + assistant) per extra turn
      # = 2 + 2 + 2 = 6 messages
      assert length(messages) == 6
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

      # Tree should be committed (includes tool result messages)
      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages) > 0
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

      # Tree should have messages from two turns
      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      # First user + assistant + second user + assistant = 4
      assert length(messages) == 4
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
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # First prompt cancel: tree rolled back to empty (origin was nil)
      assert MessageTree.messages(Agent.get_state(agent, :tree)) == []
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

  describe "terminate callback" do
    test "terminate/2 is called on normal shutdown" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        TerminateAgent.start_link(
          model: model(),
          private: %{test_pid: self()},
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      Process.unlink(agent)
      GenServer.stop(agent, :normal)
      assert_receive {:terminated, :normal}, 1000
    end

    test "terminate/2 receives shutdown reason" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        TerminateAgent.start_link(
          model: model(),
          private: %{test_pid: self()},
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      Process.unlink(agent)
      GenServer.stop(agent, :shutdown)
      assert_receive {:terminated, :shutdown}, 1000
    end
  end

  describe "step crash handling" do
    test "step crash triggers handle_error with {:step_crashed, reason}" do
      stub_name = unique_stub_name()
      test_pid = self()

      # Hang the plug so the step stays alive while we crash it
      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, :step_started)
        Process.sleep(:infinity)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end)

      {:ok, agent} =
        CrashRetryAgent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive :step_started, 2000

      server = :sys.get_state(agent)
      {step_pid, _ref} = server.step_task
      Process.exit(step_pid, :test_crash)

      # handle_error returns {:retry, state} — agent retries then hangs again
      assert_receive {:agent, ^agent, :retry, {:step_crashed, :test_crash}}, 2000
    end

    test "executor crash emits :error with {:executor_crashed, reason}" do
      stub_name = unique_stub_name()

      # Step completes with tool_use, then executor runs the hanging tool
      stub_fixture(stub_name, @tool_use_fixture)

      hanging_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> Process.sleep(:infinity) end
        )

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          tools: [hanging_tool],
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "What's the weather?")

      # Wait for step to complete and executor to spawn
      Process.sleep(200)

      server = :sys.get_state(agent)
      assert {executor_pid, _ref} = server.executor_task
      Process.exit(executor_pid, :test_crash)

      assert_receive {:agent, ^agent, :error, {:executor_crashed, :test_crash}}, 2000
    end

    test "step crash with default handle_error emits :error" do
      stub_name = unique_stub_name()
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, :step_started)
        Process.sleep(:infinity)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive :step_started, 2000

      server = :sys.get_state(agent)
      {step_pid, _ref} = server.step_task
      Process.exit(step_pid, :test_crash)

      # Default handle_error returns {:stop, state} — agent emits :error
      assert_receive {:agent, ^agent, :error, {:step_crashed, :test_crash}}, 2000
    end
  end

  # -- Error status and retry --

  describe "error status" do
    test "retry from :error re-runs evaluate_head and succeeds" do
      stub_name = unique_stub_name()
      # First call fails, second succeeds (after retry)
      stub_error_then_success(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :error

      # Retry should succeed
      :ok = Agent.retry(agent)
      events = collect_events(agent)

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
    end

    test "retry when not :error returns {:error, :not_error}" do
      {:ok, agent} = start_agent()
      assert {:error, :not_error} = Agent.retry(agent)
    end

    test "prompt from :error rolls back and starts fresh" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :error

      # Prompt from :error rolls back and starts a new round
      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent, "Try this instead!")
      events = collect_events(agent)

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # Tree should only have the successful round's messages
      messages = MessageTree.messages(Agent.get_state(agent, :tree))
      assert length(messages) == 2
    end

    test "cancel from :error rolls back and goes idle" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:error, _reason} = List.last(events)

      :ok = Agent.cancel(agent)
      events = collect_events(agent, 2000)
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      assert MessageTree.messages(Agent.get_state(agent, :tree)) == []
    end

    test "set_state from :error is allowed" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)
      assert Agent.get_state(agent, :status) == :error

      assert :ok = Agent.set_state(agent, system: "New system")
      assert Agent.get_state(agent, :system) == "New system"
    end
  end

  # -- Active navigate --

  describe "active navigate" do
    test "navigate to user message triggers regeneration" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      # Navigate to user message (node 0) — should trigger regeneration
      :ok = Agent.navigate(agent, 0)
      events = collect_events(agent)

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)

      # Node 0 should now have two children (original assistant + new branch)
      tree = Agent.get_state(agent, :tree)
      assert length(MessageTree.children(tree, 0)) == 2
    end

    test "navigate to completed assistant is passive (no events)" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)
      :ok = Agent.prompt(agent, "Second")
      _events = collect_events(agent)

      # Navigate back to node 1 (assistant) — passive, no round starts
      :ok = Agent.navigate(agent, 1)
      assert Agent.get_state(agent, :status) == :idle
      assert MessageTree.head(Agent.get_state(agent, :tree)) == 1
    end

    test "navigate to user creates sibling branch" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@text_fixture, @text_fixture])

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      tree_before = Agent.get_state(agent, :tree)
      original_assistant_id = MessageTree.head(tree_before)

      # Navigate to user msg (node 0) — regenerate
      :ok = Agent.navigate(agent, 0)
      events = collect_events(agent)
      assert {:done, %Response{}} = List.last(events)

      tree = Agent.get_state(agent, :tree)
      # Should have 2 children of node 0 (original + new)
      children = MessageTree.children(tree, 0)
      assert length(children) == 2
      # Active path should go through the new branch, not the original
      refute MessageTree.head(tree) == original_assistant_id
    end

    test "done response includes node_ids" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:done, %Response{node_ids: node_ids}} = List.last(events)
      assert is_list(node_ids)
      assert length(node_ids) == 2
      assert [0, 1] = node_ids
    end
  end
end
