defmodule Omni.Test.Baseline do
  @moduledoc false

  # Baseline integration tests: each provider records verify's text, thinking
  # and tool use scenarios, or its decision scenarios, and replays them here. Assertions hold to what a
  # provider should always give back, so they survive re-recording on a newer
  # model. Structured output has no fixture: whether the provider obeys the
  # schema is verify's job, and the response parses as plain text.
  #
  # Each assertion replays the fixture with the scenario's request and returns
  # `{response, request}`, so a test can go on to assert provider specifics on
  # either. `request` is what `Omni.Test.Capture.replay/4` reports.

  import ExUnit.Assertions

  alias Omni.{Context, Decision, Message, Model, Request, Response, Tool}
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Test.Capture
  alias Omni.Verify.Scenarios

  @doc "The context (or decision) and options a scenario sends, for capture scripts and tests."
  @spec request(atom()) :: {Context.t() | Decision.t(), keyword()}
  defdelegate request(scenario), to: Scenarios

  @doc "Turn 2 of a two-turn scenario."
  @spec follow_up(atom(), Context.t(), Response.t()) :: Context.t()
  defdelegate follow_up(scenario, context, resp), to: Scenarios

  @doc """
  The next step of a tool loop: `context` plus the response's message and a
  user message with its tool results, run by the context's tool handlers.
  """
  @spec tool_round(Context.t(), Response.t()) :: Context.t()
  def tool_round(%Context{} = context, %Response{message: message}) do
    tool_uses = Enum.filter(message.content, &match?(%ToolUse{}, &1))
    results = Tool.Runner.run(tool_uses, Map.new(context.tools, &{&1.name, &1}))

    %{
      context
      | messages: context.messages ++ [message, Message.new(role: :user, content: results)]
    }
  end

  @doc "Asserts a text response: stop, text, usage."
  def assert_text(%Model{} = model, file, opts \\ []) do
    {resp, request} = replay(:text, model, file, opts)

    assert resp.stop_reason == :stop
    assert text_of(resp) != ""
    assert_usage(resp)
    {resp, request}
  end

  @doc """
  Asserts a thinking response: text, and thinking by verify's lenient rule
  (thinking text, a signature, redacted data, a signed text block or encrypted
  reasoning details). Whether a model reasons varies, so this shows the
  request for thinking was understood, not that the model thought.
  """
  def assert_thinking(%Model{} = model, file, opts \\ []) do
    {resp, request} = replay(:thinking, model, file, opts)

    assert resp.stop_reason == :stop
    assert text_of(resp) != ""
    assert {:ok, _} = Scenarios.thinking_of(resp)
    assert_usage(resp)
    {resp, request}
  end

  @doc "Asserts a tool use response: a `get_weather` call for London."
  def assert_tool_use(%Model{} = model, file, opts \\ []) do
    {resp, request} = replay(:tool_use, model, file, opts)

    assert resp.stop_reason == :tool_use
    assert %ToolUse{} = tool_use = Enum.find(resp.message.content, &match?(%ToolUse{}, &1))
    assert tool_use.name == "get_weather"
    assert is_binary(tool_use.id) and tool_use.id != ""
    assert inspect(tool_use.input) =~ ~r/london/i
    assert_usage(resp)
    {resp, request}
  end

  @doc """
  Asserts a decision response by verify's rule: every answer well formed and
  the clear-cut questions answered as expected. `scenario` is `:decision` or
  `:decision_json`.
  """
  def assert_decision(%Model{} = model, scenario, file, opts \\ [])
      when scenario in [:decision, :decision_json] do
    {decision, request} = replay(scenario, model, file, opts)
    assert Scenarios.check_decision(scenario, decision) == :ok
    {decision, request}
  end

  @doc """
  The JSON body a scenario's request sends, built without sending it. For
  request shape assertions that need no response, such as structured output,
  or a decision's encoding.
  """
  @spec request_body(Model.t(), atom()) :: map()
  def request_body(%Model{} = model, scenario) do
    {input, opts} = request(scenario)
    assert {:ok, req} = Request.build(model, input, Keyword.put(opts, :api_key, "test-key"))
    req.options.json |> JSON.encode!() |> JSON.decode!()
  end

  @doc """
  Replays a scenario's fixture, then builds the next request with the
  response in its history, without sending it. Returns the response's
  thinking text and the assistant message as the next request sends it, for
  asserting where a provider puts earlier reasoning.
  """
  @spec replay_thinking(Model.t(), atom(), String.t()) :: {String.t(), map()}
  def replay_thinking(%Model{} = model, scenario, file) do
    {resp, _request} = replay(scenario, model, file, [])

    thinking =
      resp.message.content
      |> Enum.filter(&match?(%Thinking{text: text} when is_binary(text), &1))
      |> Enum.map_join(& &1.text)

    assert thinking != ""

    {context, opts} = request(scenario)
    turn2 = %{context | messages: context.messages ++ [resp.message, Message.new("Thanks.")]}

    assert {:ok, req} = Request.build(model, turn2, Keyword.put(opts, :api_key, "test-key"))
    body = req.options.json |> JSON.encode!() |> JSON.decode!()

    {thinking, Enum.find(body["messages"], &(&1["role"] == "assistant"))}
  end

  @doc """
  Asserts a real cache hit across the cache scenario's two turns: turn 2 reads
  cached tokens, and `input_tokens` counts only the uncached rest. Returns both
  responses.
  """
  def assert_cache_hit(%Model{} = model, turn1_file, turn2_file, opts \\ []) do
    {context, scenario_opts} = request(:cache_usage)
    opts = Keyword.merge(opts, scenario_opts)

    assert {:ok, %Response{} = resp1} = Capture.replay(model, context, turn1_file, opts)
    turn2 = follow_up(:cache_usage, context, resp1)
    assert {:ok, %Response{} = resp2} = Capture.replay(model, turn2, turn2_file, opts)

    assert resp1.usage.cache_read_tokens == 0
    assert resp2.usage.cache_read_tokens > 0
    assert resp2.usage.input_tokens < resp2.usage.cache_read_tokens
    {resp1, resp2}
  end

  @doc """
  Asserts where a request goes and how it authenticates: the host and path of
  `url`, and each of `headers`. Replays `file` as the response to the
  `:scenario` option's request (default `:text`), sent with the API key
  `"test-key"`.
  """
  def assert_target(%Model{} = model, file, url, headers, opts \\ []) do
    {scenario, opts} = Keyword.pop(opts, :scenario, :text)
    {_resp, request} = replay(scenario, model, file, opts)
    uri = URI.parse(url)

    assert request.host == uri.host
    assert request.path == uri.path

    for header <- headers do
      assert header in request.headers
    end

    request
  end

  defp replay(scenario, model, file, opts) do
    {input, scenario_opts} = request(scenario)

    assert {:ok, resp} = Capture.replay(model, input, file, Keyword.merge(opts, scenario_opts))

    assert_received {:replay_request, request}
    {resp, request}
  end

  defp assert_usage(resp) do
    assert resp.usage.input_tokens > 0
    assert resp.usage.output_tokens > 0
  end

  defp text_of(resp) do
    resp.message.content
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join(& &1.text)
    |> String.trim()
  end
end
