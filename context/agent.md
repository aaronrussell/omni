# Omni Agent Design

**Status:** Implemented
**Last updated:** March 2026

---

## Overview

`Omni.Agent` is a GenServer-based building block for stateful, long-running LLM interactions. It wraps Omni's existing `stream_text`/`generate_text` pipeline in a supervised process that manages its own conversation context, executes tools, and communicates with callers via process messages.

The core idea: an agent is a process that holds a model, a conversation tree, tools, and user-defined state. The outside world sends prompts in; the agent works on them (potentially across multiple LLM turns) and sends events back. Users control agent behaviour through a set of lifecycle callbacks.

### What the agent is

- A supervised GenServer process
- Manages its own conversation tree (`%MessageTree{}`), system prompt, and tools
- Communicates asynchronously via process messages
- Behaviour controlled by user-defined callbacks with sensible defaults
- A building block, not a framework -- users compose agents into larger systems

### What the agent is not

- Not a task planner or goal decomposer -- that's application logic
- Not a multi-agent orchestration system -- that sits above the agent
- Not a memory/RAG system -- that's a separate concern
- Not a replacement for `stream_text`/`generate_text` -- those remain the stateless API

---

## Relationship to existing architecture

Omni already has two key pieces:

- **`Omni.Loop`** -- handles tool auto-execution and structured output validation within a single `stream_text` / `generate_text` call. Stateless, lazy stream pipeline.
- **`Omni.stream_text/3` / `Omni.generate_text/3`** -- stateless functions. Caller provides context, gets a response, manages conversation history externally.

The agent adds:

- **State management** -- the agent holds the conversation tree so the caller doesn't have to thread messages through.
- **Its own loop** -- after each LLM turn completes, the agent decides whether to continue (re-prompt) or stop, based on user-defined callbacks.
- **Lifecycle hooks** -- callbacks for intercepting tool execution, handling errors, and controlling continuation.

The agent does **not** use `Omni.Loop` for tool execution. It calls `stream_text` with `max_steps: 1`, so Loop handles single-step streaming, event parsing, and structured output validation but never enters its tool execution loop. The agent manages tool execution itself via lifecycle callbacks (`handle_tool_call`, `handle_tool_result`), enabling per-tool approval gates and pause/resume that Loop's stateless design cannot support.

```
┌─────────────────────────────────────────────────┐
│  Omni.Agent (GenServer)                         │
│  - Manages conversation tree and state           │
│  - Decides continue/stop between turns          │
│  - Lifecycle callbacks                          │
│  - Tool execution with per-tool interception    │
│                                                 │
│  Uses stream_text(max_steps: 1) per step:        │
│  ┌───────────────────────────────────────────┐  │
│  │  Single LLM request via Omni.Loop         │  │
│  │  - Streaming event pipeline               │  │
│  │  - Structured output validation           │  │
│  │  - No tool looping (max_steps: 1)         │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Agent definition

### Starting an agent

`Omni.Agent` is the GenServer module. It accepts an optional callback module for custom behaviour:

```elixir
# No custom module -- default callbacks (single turn per prompt, no interception)
{:ok, agent} = Omni.Agent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a helper."
)

# Custom module -- Omni.Agent dispatches to MyAgent's callbacks
{:ok, agent} = Omni.Agent.start_link(MyAgent,
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a research assistant.",
  tools: [SearchTool.new(), FetchTool.new()]
)
```

`Omni.Agent.start_link/1` (opts only) and `Omni.Agent.start_link/2` (module + opts).

### Custom agent modules

`use Omni.Agent` generates a `start_link/1` that delegates to `Omni.Agent.start_link/2` with the module baked in:

```elixir
defmodule MyAgent do
  use Omni.Agent

  def handle_stop(%{stop_reason: :length}, state) do
    {:continue, "Continue where you left off.", state}
  end
  def handle_stop(_response, state), do: {:stop, state}
end

{:ok, agent} = MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a research assistant."
)
```

For reusable defaults, override `start_link` -- standard GenServer pattern:

```elixir
defmodule MyAgent do
  use Omni.Agent

  def start_link(opts \\ []) do
    defaults = [
      model: {:anthropic, "claude-sonnet-4-20250514"},
      system: "You are a research assistant.",
      tools: [SearchTool.new(), FetchTool.new()]
    ]
    super(Keyword.merge(defaults, opts))
  end

  # callbacks...
end

MyAgent.start_link()                              # uses defaults
MyAgent.start_link(model: {:openai, "gpt-4o"})   # overrides model
```

All configuration flows through `start_link` opts. No config in the `use` macro -- the module provides behaviour (callbacks), `start_link` provides configuration (data). This avoids merge ambiguity and handles dynamic values naturally.

### GenServer options

Known GenServer keys (`:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug`) are extracted from the flat opts and passed to `GenServer.start_link/3`. No nested `:server` key:

```elixir
MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  name: {:via, Registry, {MyRegistry, :agent_1}}
)
```

### Agent opts (passed through to stream_text)

LLM request options (`:temperature`, `:max_tokens`, etc.) are passed under the `:opts` key to keep them separate from agent-level configuration:

```elixir
MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a helper.",
  tool_timeout: 10_000,
  opts: [temperature: 0.7, max_tokens: 4096]
)
```

`:tool_timeout` sets the maximum time (in milliseconds) for each individual tool execution. Defaults to `5_000` (5 seconds). When a tool exceeds this timeout, its Tool Task is killed and an error `ToolResult` is sent to the model. Applied uniformly to all tools — no per-tool configuration.

---

## Agent state

Agent state is split into two structs: a public `%Omni.Agent.State{}` passed to all callbacks, and an internal `%Omni.Agent.Server{}` struct that wraps it alongside GenServer machinery. Callback implementors only see the public struct.

### Public state (`Omni.Agent.State`)

The public state is a 10-field struct. User-defined state is split into `meta` (serializable, persisted by storage) and `private` (runtime, not persisted).

```elixir
defmodule Omni.Agent.State do
  defstruct [
    :session_id,                      # String.t() — unique session identifier
    :model,                           # %Model{} — the agent's model
    :opts,                            # keyword — agent-level default inference opts
    system: nil,                      # String.t() | nil — system prompt
    tools: [],                        # [Tool.t()] — available tools
    tree: %MessageTree{},             # %MessageTree{} — conversation tree
    meta: %{},                        # serializable user data (persisted by storage)
    private: %{},                     # runtime state (PIDs, refs — not persisted)
    status: :idle,                    # :idle | :running | :paused
    step: 0                           # current step counter within the active round
  ]
end
```

The fields have two logical tiers:

- **Configuration** — `model`, `system`, `tools`, and `opts` are set at `start_link` and changeable via `configure/2,3` (idle only). `opts` holds agent-level inference defaults (`:temperature`, `:max_tokens`, `:max_steps`, etc.).
- **Session state** — `session_id`, `tree`, `meta`, `private`, `status`, and `step` change during operation. `tree` holds the full conversation history as a `%MessageTree{}`. `meta` is serializable user data. `private` is runtime state. `step` resets per prompt round.

All callbacks receive this public `%State{}` struct. Users can read any field and primarily read/write `meta` and `private`. The framework manages the other fields.

Note: `tree` reflects the committed state — it only includes messages from completed prompt rounds. In-progress messages are tracked internally and are not visible in `tree` until the round completes. See "Context management" section.

Usage is not cached on state — `Agent.usage/1` computes it via `MessageTree.usage/1`, which sums all rounds in the tree.

### Internal server state (`Omni.Agent.Server`)

The server struct wraps the public state and adds all internal machinery. It is never passed to callbacks.

```elixir
defstruct [
  # Public state (passed to callbacks)
  :state,                             # %State{} — the public struct

  # Configuration (set at init, stable across rounds)
  :module,                            # module() | nil — callback module
  :listener,                          # pid | nil — event recipient
  :tool_timeout,                      # timeout — per-agent tool execution timeout

  # Round lifecycle (reset per prompt round)
  pending_messages: [],               # in-progress message accumulator
  pending_usage: %Usage{},            # accumulated usage for current round
  prompt_opts: [],                    # per-round merged opts
  next_prompt: nil,                   # staged prompt (steering)
  last_response: nil,                 # most recent Response from a step

  # Process tracking
  step_task: nil,                     # {pid, ref} | nil — current step process
  executor_task: nil,                 # {pid, ref} | nil — current executor process

  # Tool decision phase (set when decisions begin, cleared by reset_round)
  tool_map: nil,                      # name → Tool lookup
  approved_uses: [],                  # already-approved tool uses (reversed)
  remaining_uses: [],                 # tool uses not yet presented to handle_tool_call
  rejected_results: [],               # stashed rejected tool results
  paused_use: nil                     # the tool_use awaiting a human decision
]
```

`pending_messages` and `pending_usage` accumulate together during a round and are both reset by `reset_round/1`. On round commit, they are passed to `MessageTree.push/3`.

### Usage accumulation

Usage is not cached on `%State{}`. Each step's usage accumulates into `server.pending_usage` during a round. On round commit, `pending_usage` is stored in the `MessageTree` round via `push/3`. `Agent.usage/1` computes the total via `MessageTree.usage/1`, which sums all rounds in the tree — including inactive branches (total API spend, not just the active conversation path).

`Agent.clear/1` replaces the tree with a fresh `%MessageTree{}`, so `usage/1` returns `%Usage{}` after clear.

### What the state does NOT store

- **Responses** — the listener receives `%Response{}` via `:turn` and `:done` events. If the listener wants to collect responses, it does so in its own process state. Storing responses on the agent would grow memory unboundedly for long-running agents.
- **Raw request/response pairs** — the `:raw` option can be passed per-prompt via `prompt/3` opts and flows through to `stream_text`. Each `%Response{}` delivered via events carries its own `raw` field. The agent does not accumulate raw data.

### max_steps lives in opts

`max_steps` is stored in `opts` (the agent-level default) and can be overridden per-prompt via `prompt/3` opts. The per-prompt override is ephemeral — it only applies to that prompt round. Next round, the agent falls back to the default in `opts`. This is handled via keyword merge into `prompt_opts` at the start of each round.

---

## Public API

The agent communicates with callers via process messages. This is the natural Elixir pattern for long-lived processes and works well with GenServers, LiveViews, and Phoenix Channels.

### Full API surface

```elixir
# Lifecycle
Omni.Agent.start_link(opts)                        # no custom module
Omni.Agent.start_link(module, opts)                # with callback module

# Interaction
Agent.prompt(agent, content, opts \\ [])           # send prompt / steer
Agent.resume(agent, decision)                      # resume from tool approval pause
Agent.cancel(agent)                                # abort and rollback

# Configuration (idle only)
Agent.configure(agent, opts)                       # → :ok | {:error, ...}
Agent.configure(agent, field, updater_fn)          # → :ok | {:error, ...}

# Navigation (idle only)
Agent.navigate(agent, round_id)                    # → {:ok, %MessageTree{}} | {:error, ...}
Agent.clear(agent)                                 # → {:ok, session_id} | {:error, :running}

# Listener
Agent.listen(agent, pid)                           # → :ok | {:error, :running}

# Inspection
Agent.get_state(agent)                             # → %State{}
Agent.get_state(agent, :model)                     # → %Model{}
Agent.get_state(agent, :status)                    # → :idle | :running | :paused
Agent.usage(agent)                                 # → %Usage{}

# Tool management (idle only)
Agent.add_tools(agent, tools)                      # → :ok | {:error, :running}
Agent.remove_tools(agent, tool_names)              # → :ok | {:error, :running}
```

### prompt/2,3

```elixir
# Simple text prompt
:ok = Agent.prompt(agent, "Do some research on Elixir web frameworks")

# With attachments (content blocks)
:ok = Agent.prompt(agent, [
  Text.new("What's in this image?"),
  Attachment.new(source: {:base64, data}, media_type: "image/png")
])

# With per-prompt option overrides
:ok = Agent.prompt(agent, "Do some research",
  max_steps: 50,
  temperature: 0.7,
  max_tokens: 100
)

# Steering -- prompt while running or paused stages for next turn boundary
:ok = Agent.prompt(agent, "Focus on X instead")
```

`prompt/2,3` is a `GenServer.call`. The `content` argument accepts a string (wrapped in a `Text` block) or a list of content blocks (for attachments, or `ToolResult` blocks for manual tool execution — see "Schema-only tools and manual execution"). The agent constructs the user `Message` internally. Options: `:max_steps` overrides the agent's step limit for this prompt round only (see "Steps and turns"). Everything else is passed through to `stream_text` as per-prompt inference overrides.

If no listener has been set (via `Agent.listen/2`), the first `prompt/3` call automatically sets the caller as the listener. See "Listener" section below.

Behaviour depends on agent status:

- **Idle**: starts working immediately. Events arrive as process messages to the listener.
- **Running or Paused**: the prompt is staged as a pending prompt. At the next turn boundary, the pending prompt overrides `handle_stop`'s decision (see "Prompt queuing"). Calling `prompt/3` again replaces the staged prompt — last-one-wins. The caller is assumed to be the same entity updating its intent.

### resume/2

```elixir
Agent.resume(agent, :approve)              # approve the paused tool call
Agent.resume(agent, {:reject, reason})     # reject with reason
```

Only valid when the agent is `:paused` (from `handle_tool_call` returning `{:pause, state}`). Returns `{:error, :not_paused}` otherwise. See "Pause and resume" section below.

### cancel/1

```elixir
Agent.cancel(agent)
```

Aborts the current operation. Kills any running Step/Executor/Tool Tasks, discards pending messages, tree unchanged. The agent returns to `:idle`. See "Context management" section below.

Works when `:running` or `:paused`. Returns `{:error, :idle}` if already idle.

### clear/1

```elixir
{:ok, new_session_id} = Agent.clear(agent)
```

Starts a new session. Generates a new session ID and replaces the tree with a fresh `%MessageTree{}`. Preserves system prompt, tools, model, opts, meta, and private. Returns `{:ok, new_session_id}`. Only valid when `:idle`; returns `{:error, :running}` otherwise.

This is distinct from `navigate/2`: navigating moves the cursor within the same session and tree. `clear/1` creates a clean slate with a new session ID.

### add_tools/2, remove_tools/2

```elixir
:ok = Agent.add_tools(agent, [NewTool.new()])
:ok = Agent.remove_tools(agent, ["old_tool"])
```

Modify the agent's tool set. Only valid when the agent is `:idle` — returns `{:error, :running}` if the agent is running or paused. This avoids race conditions with in-progress tool execution.

### Listener

The listener is the process that receives `{:agent, pid, type, data}` events. Managed separately from prompting:

```elixir
# Explicit — set before or after first prompt (idle only)
Agent.listen(agent, self())

# Implicit — first prompt/3 caller becomes listener if none set
:ok = Agent.prompt(agent, "hello")   # caller is now the listener
```

The listener starts as `nil` after `start_link`. The first `prompt/3` call sets the caller as the listener if none has been explicitly set. After that, the listener persists across prompt rounds until explicitly changed via `listen/2`.

`listen/2` returns `:ok` when idle, `{:error, :running}` otherwise — same idle-only constraint as `add_tools/remove_tools`. This avoids mid-round listener changes and the ambiguity of who receives in-flight events.

Typical patterns:

- **Unsupervised (IEx, scripts)**: call `prompt/3` directly — caller auto-becomes listener.
- **Supervised (LiveView)**: supervisor starts the agent, LiveView calls `prompt/3` — LiveView auto-becomes listener.
- **Explicit handoff**: call `listen/2` when idle to switch the listener to a different process.

### Inference opts merge order

Per-prompt inference options (passed through `prompt/3`) merge on top of agent-level defaults (set in `start_link` under `:opts`). Agent defaults ← per-prompt opts. The merged options are passed to `stream_text` for each step.

### Event format

All events from the agent follow the format `{:agent, agent_pid, event_type, event_data}`:

```elixir
# SR pass-through events (streaming content from each step)
# Data is the map from StreamingResponse, with the partial Response stripped.
{:agent, pid, :text_start, %{index: 0}}
{:agent, pid, :text_delta, %{index: 0, delta: "Hello"}}
{:agent, pid, :text_end, %{index: 0, content: %Text{}}}
{:agent, pid, :thinking_start, %{index: 0}}
{:agent, pid, :thinking_delta, %{index: 0, delta: "..."}}
{:agent, pid, :thinking_end, %{index: 0, content: %Thinking{}}}
{:agent, pid, :tool_use_start, %{index: 1, id: "call_1", name: "search"}}
{:agent, pid, :tool_use_delta, %{index: 1, delta: "{\"q\":"}}
{:agent, pid, :tool_use_end, %{index: 1, content: %ToolUse{}}}

# Agent-level events
{:agent, pid, :tool_result, %ToolResult{}}    # after tool execution
{:agent, pid, :turn, %Response{}}             # intermediate turn complete, agent continuing
{:agent, pid, :done, %Response{}}             # prompt round complete
{:agent, pid, :pause, %ToolUse{}}             # waiting for tool approval
{:agent, pid, :cancelled, nil}                # cancel was invoked
{:agent, pid, :retry, reason}                # non-terminal error, agent retrying step
{:agent, pid, :error, reason}                # terminal error, round is over
```

**SR pass-through events** are forwarded from the Step Task as the LLM streams its response. The partial `%Response{}` from `StreamingResponse` is stripped — the listener doesn't need the accumulating state on every delta. The completed response arrives with `:turn` or `:done`.

**Agent-level events** are emitted by the GenServer itself. The 4th element is whatever type is natural for the event — structs for `:tool_result`, `:turn`, `:done`, `:pause`; `nil` for `:cancelled`; a bare term for `:error`.

SR events `:done` and `:error` are not forwarded — they are internal to the step. The agent emits its own `:done` and `:error` events at the prompt round level. `:retry` is emitted when `handle_error` returns `{:retry, state}` — it carries the error reason and signals that a new step will follow. `:error` is always terminal (round is over).

**Turn boundaries:** `:turn` fires after each intermediate turn (where `handle_stop` returned `{:continue, ...}`). `:done` fires after the final turn. The last turn gets `:done`, not `:turn` — no doubling up. A simple chatbot (one turn per prompt) never sees `:turn`, only `:done`.

```
# Simple chatbot (1 turn, no tools)
text_delta, text_delta, ..., done

# Single turn with tools
text_delta, tool_use_start, ..., tool_use_end, tool_result,
text_delta, ..., done

# Autonomous agent (3 turns)
text_delta, ..., tool_use_end, tool_result, text_delta, ..., turn,
text_delta, ..., turn,
text_delta, ..., done
```

### Usage patterns

In a receive loop (scripts, IEx):

```elixir
:ok = Agent.prompt(agent, "Do the thing")

receive do
  {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
  {:agent, ^agent, :pause, tool_use} ->
    Agent.resume(agent, :approve)
  {:agent, ^agent, :done, response} -> handle_result(response)
end
```

In a LiveView:

```elixir
def handle_event("submit", %{"prompt" => text}, socket) do
  :ok = Agent.prompt(socket.assigns.agent, text)
  {:noreply, socket}
end

def handle_info({:agent, _pid, :text_delta, %{delta: text}}, socket) do
  {:noreply, stream_insert(socket, :messages, %{type: :text, text: text})}
end

def handle_info({:agent, _pid, :turn, _response}, socket) do
  {:noreply, assign(socket, :status, "Agent continuing...")}
end

def handle_info({:agent, _pid, :done, response}, socket) do
  {:noreply, assign(socket, status: "Complete", response: response)}
end

def handle_info({:agent, _pid, :cancelled, _}, socket) do
  {:noreply, assign(socket, :status, "Cancelled")}
end
```

---

## Process architecture

The agent GenServer never blocks on IO. All blocking work (LLM requests, tool execution) is delegated to spawned Tasks. This keeps the GenServer responsive for cancel, state inspection, and resume calls at all times.

### Three Task layers

- **Step Task** -- one per LLM request (step). Calls `stream_text` with `max_steps: 1`, enumerates the `StreamingResponse`, and forwards events to the GenServer via a tagged ref. The Task owns the HTTP connection via `Req.request(into: :self)` -- Finch messages go to the Task's mailbox, not the GenServer's. Internal message format: `{step_ref, {:event, type, map}}` for streaming events, `{step_ref, {:complete, %Response{}}}` on success, `{step_ref, {:error, reason}}` on failure. The GenServer strips the ref, forwards streaming events to the listener (see "Event format"), and handles completion internally.

- **Executor Task** -- one per tool execution batch. Spawns individual Tool Tasks in parallel using a shared parallel execution utility (see below), collects results via `Task.await_many`, and sends all results back to the GenServer.

- **Tool Tasks** -- one per tool. Spawned by the executor. Calls `Tool.execute/2` for a single tool. Short-lived.

### Flow

```
Agent GenServer                Step Task             Listener
     │                              │
     │  spawn step ────────────────▶│
     │                              │──── stream_text(max_steps: 1)
     │◀── {ref, {:event, ...}} ────│                  │
     │────── {:agent, pid, type, data} ──────────────▶│  (forwarded)
     │◀── {ref, {:event, ...}} ────│                  │
     │────── {:agent, pid, type, data} ──────────────▶│  (forwarded)
     │◀── {ref, {:complete, resp}} │
     │
     │  handle_tool_call(A) → :execute
     │  handle_tool_call(B) → :execute
     │  handle_tool_call(C) → :pause
     │     → GenServer pauses
     │────── {:agent, pid, :pause, %ToolUse{C}} ────▶│
     │
     │◀── Agent.resume(:approve)
     │
     │                         Executor Task         Tool Tasks
     │  spawn executor ──────────▶ │
     │  (GenServer free)           │── Task.async(A) ──▶ [A]
     │                             │── Task.async(B) ──▶ [B]
     │                             │── Task.async(C) ──▶ [C]
     │                             │   Task.yield_many
     │◀── {:tools_executed, [...]} │
     │
     │  handle_tool_result(A, result_a) → {:ok, ...}
     │────── {:agent, pid, :tool_result, %ToolResult{A}} ──▶│
     │  handle_tool_result(B, result_b) → {:ok, ...}
     │────── {:agent, pid, :tool_result, %ToolResult{B}} ──▶│
     │  handle_tool_result(C, result_c) → {:ok, ...}
     │────── {:agent, pid, :tool_result, %ToolResult{C}} ──▶│
     │
     │  build_context, spawn next Step Task
```

### Why this design

Using `Req.request(into: :self)` inside a GenServer is technically safe -- Finch tags messages with a unique ref, and selective receive avoids conflicts with GenServer protocol messages. But the stream consumer blocks with an infinite `receive`, which would make the GenServer unresponsive for the entire duration of each LLM response. Spawning a Step Task avoids this entirely.

The same reasoning applies to tool execution -- tools may involve HTTP calls or other IO. The executor Task keeps tool execution off the GenServer.

### Fault tolerance

All tasks are linked to the GenServer but designed never to crash — task bodies are wrapped in try/rescue and always send a result message. The GenServer traps exits as defense-in-depth. No `Task.Supervisor` needed.

**Step process** — uses `Task.start_link/1` (not `Task.async`, since it sends multiple messages rather than a single result). Wraps its body in try/rescue. On success, sends `{ref, {:complete, response}}`. On exception, sends `{ref, {:error, reason}}`. The GenServer routes errors to `handle_error` as normal. A bug in dialect parsing or an unexpected network error becomes a handled error, not a process crash.

**Executor Task** — uses `Task.yield_many/2` instead of `Task.await_many/2` to collect tool results. This handles per-tool timeouts and crashes gracefully without raising:

```elixir
tasks
|> Task.yield_many(timeout)
|> Enum.map(fn
  {task, {:ok, result}} -> result                         # {:ok, val} or {:error, err}
  {task, {:exit, reason}} -> {:error, reason}             # task crashed (shouldn't happen)
  {task, nil} -> Task.shutdown(task); {:error, :timeout}  # exceeded tool_timeout
end)
```

Each tool gets its own outcome regardless of what happened to other tools. A timed-out tool doesn't affect the results of tools that completed successfully.

**Tool Tasks** — `Tool.execute/2` already has its own rescue block, so Tool Tasks virtually never crash. The `yield_many` handling above is defense-in-depth.

### Parallel tool execution utility

`Omni.Tool.Runner` provides shared parallel tool execution, used by both the agent's `Executor` and `Omni.Loop`:

```elixir
# Omni.Tool.Runner
@spec run([ToolUse.t()], %{String.t() => Tool.t()}, timeout()) :: [ToolResult.t()]
def run(tool_uses, tool_map, timeout \\ 5_000)
```

Takes a list of `ToolUse` content blocks and a map of tool names to `Tool` structs. Returns `[ToolResult.t()]` in the same order as the input `tool_uses`. Each tool runs in a separate `Task.async`, collected via `Task.yield_many/2`. Handles: missing tools (hallucinated names → error results), tool exceptions (→ error results), timeouts (→ shutdown + error results).

This is a content-block-level orchestration layer on top of the low-level `Tool.execute/2` primitive. `Tool.execute/2` takes a tool struct and a raw input map; `Tool.Runner.run/3` takes `ToolUse` blocks and resolves tools by name.

The agent passes its `:tool_timeout` value (default 5 seconds). `Omni.Loop` also uses `Tool.Runner.run/3`, giving all `stream_text`/`generate_text` callers parallel tool execution.

### Tool call decision flow

When the model produces tool use blocks, the GenServer first checks whether all tools have handlers. If any tool is schema-only (no handler), the entire response goes straight to `handle_stop` with `stop_reason: :tool_use` — no decision phase, no execution. This matches `Omni.Loop`'s `all_executable?` gate. The model expects results for all tool uses in a single message, so partial execution isn't an option.

In practice, schema-only tools in agents are almost exclusively completion signals (like `task_complete`). Any other schema-only tool alongside executable tools is likely a mistake. The user handles everything in `handle_stop` — see "Schema-only tools and manual execution" below.

When all tools have handlers, the GenServer processes them in two phases:

1. **Decision phase** (synchronous, in GenServer): iterate tool uses, invoke `handle_tool_call` for each. Collect decisions (`:execute`, `{:reject, reason}`, or `{:pause}`). Rejected tools get error `ToolResult`s immediately without execution. When `{:pause, state}` is returned, the decision loop is interrupted — the agent saves its position and waits for `Agent.resume/2` before continuing with remaining tools.

2. **Execution phase** (async, in executor Task): approved tools execute in parallel via `Tool.Runner.run/3`. Results sent back to GenServer. GenServer merges with rejected results (reordered to match original tool_use order), then invokes `handle_tool_result` for each.

Per-tool decisions produce per-tool outcomes. Rejecting tool C does not affect tools A and B -- they execute normally, and C gets an error result. The model receives all results in a single user message and adapts.

---

## Lifecycle callbacks

All callbacks are optional with `defoverridable` defaults. Users implement only the callbacks they need. Defaults are trivial (e.g., `{:stop, state}`) so catch-all clauses are easy to write inline — no `super()` needed.

### init/1

Called once when the agent starts. Receives the full opts passed to `start_link` (including framework keys like `model:`, `system:` -- the user ignores what they don't need). Returns `{:ok, private}` or `{:error, reason}`.

```elixir
def init(opts) do
  case MyApp.Repo.get(User, opts[:user_id]) do
    nil -> {:error, :user_not_found}
    user -> {:ok, %{user: user, results: []}}
  end
end
```

Return values:
- `{:ok, private}` -- start successfully with this runtime state (populates `state.private`)
- `{:error, reason}` -- refuse to start (`start_link` returns `{:error, reason}`)

Default: `{:ok, %{}}` (empty private).

### handle_tool_call/2

Called before a tool is executed, during the decision phase. Receives the tool use struct and agent state. Called sequentially for each tool use in the model's response -- all decisions are collected before any tool executes.

```elixir
def handle_tool_call(tool_use, state) do
  {:execute, state}                # proceed with execution
  {:reject, reason, state}         # send error result to model
  {:pause, state}                  # pause, wait for external decision
end
```

Default: `{:execute, state}` (execute all tools).

Use cases: approval gates, logging, rate limiting, input modification.

When `{:pause, state}` is returned, the agent enters paused state and sends `{:agent, pid, :pause, tool_use}` to the listener. The caller inspects the tool call and resumes with `Agent.resume(agent, :approve)` or `Agent.resume(agent, {:reject, reason})`.

### handle_tool_result/2

Called after a tool executes, during the result phase. Receives the `%ToolResult{}` and agent state. Called sequentially for each result after all approved tools have executed in parallel. The `ToolResult` carries `tool_use_id` and `name` for identifying which tool produced it.

```elixir
def handle_tool_result(result, state) do
  {:ok, result, state}             # pass through
  {:ok, modified_result, state}    # modify before sending to model
end
```

Default: `{:ok, result, state}` (pass through).

Use cases: logging, caching, result augmentation.

### handle_stop/2

Called after each LLM turn completes and tool execution (if any) has been handled. Receives the `%Response{}` from the most recent Step Task and agent state. The stop reason is available as `response.stop_reason`.

```elixir
def handle_stop(response, state) do
  {:stop, state}                   # done, return response to caller
  {:continue, prompt, state}       # append user message, go again
end
```

Default: `{:stop, state}` (always stop after one turn).

`handle_stop` fires at the end of each turn — after the model responds without calling tools (or with only schema-only tools). When the model calls executable tools, the agent handles them via `handle_tool_call`/`handle_tool_result`, fires another Step Task with the tool results, and the loop continues until the model stops calling tools. `handle_stop` fires on the final response of each turn. The stop reasons that typically reach `handle_stop`:

- `:stop` -- the model finished naturally (text response, no pending tool calls)
- `:tool_use` -- the model called a schema-only tool (no handler), signaling completion (see "Completion tool pattern")
- `:length` -- output was truncated (hit max output tokens)
- `:error` -- the API returned an error response

Note: if a pending prompt exists (from `prompt/3` while running), it overrides `handle_stop`'s return value. See "Prompt queuing" section.

### handle_error/2

Called when the LLM request fails entirely -- `Omni.generate_text` returned `{:error, reason}` rather than a `%Response{}`. This is distinct from `handle_stop` with an error stop reason, which means the request succeeded but the API returned an error in the response.

```elixir
def handle_error(error, state) do
  {:stop, state}                   # give up, return error to caller
  {:retry, state}                  # try the same turn again
end
```

Default: `{:stop, state}` (surface the error to the caller).

Use cases: retry logic for transient failures, fallback to a different model, error reporting.

Note: HTTP-level retries (429, 529, etc.) should be handled by Req middleware before reaching the agent. `handle_error` is for errors that survive the middleware layer.

### terminate/2

Called when the agent process is shutting down. Receives the shutdown reason and agent state. Use for cleaning up resources acquired in `init/1` (DB connections, linked processes, etc.).

```elixir
def terminate(reason, state) do
  MyApp.ResourcePool.release(state.private.resource)
  :ok
end
```

Default: no-op.

Called from `Omni.Agent`'s GenServer `terminate/2`, which delegates to the user's callback module. The user's module is not itself a GenServer, so this callback is the only way to hook into process shutdown.

---

## Autonomous agents and the completion signal

The difference between a chatbot (single turn per prompt) and an autonomous agent (works until done) is entirely in the callbacks. The framework doesn't distinguish between these modes.

### The completion tool pattern

An autonomous agent uses a schema-only tool (no handler) as its completion signal:

```elixir
task_complete = Omni.Tool.new(
  name: "task_complete",
  description: "Call this when you have fully completed the task.",
  input_schema: %{result: %{type: "string", description: "Summary of what was accomplished"}}
)
```

When the model calls `task_complete`, the agent sees a schema-only tool (no handler) and skips the decision phase entirely. The response arrives at `handle_stop` with `stop_reason: :tool_use`. The callback inspects the response, finds `task_complete`, and returns `{:stop, state}`.

```elixir
def handle_stop(%{stop_reason: :tool_use} = response, state) do
  case find_tool_use(response, "task_complete") do
    %{input: %{"result" => result}} ->
      state = %{state | private: Map.put(state.private, :result, result)}
      {:stop, state}
    nil ->
      {:stop, state}
  end
end

def handle_stop(%{stop_reason: :length}, state) do
  {:continue, "You were cut off. Continue from where you left off.", state}
end

def handle_stop(%{stop_reason: :stop}, state) do
  # Model produced text without calling task_complete -- re-prompt
  {:continue, "Continue working on the task. Call task_complete when finished.", state}
end

def handle_stop(_response, state) do
  {:stop, state}
end
```

### Schema-only tools and manual execution

When `handle_stop` fires with `stop_reason: :tool_use`, the user may want to execute the tool manually and send results back to the model. No special API is needed — since Omni uses user messages for tool results (no `:tool` role), `ToolResult` blocks are just content blocks that work with existing primitives.

**Synchronous** — handle it inline in `handle_stop` and continue:

```elixir
def handle_stop(%{stop_reason: :tool_use} = response, state) do
  results = response.message.content
  |> Enum.filter(&match?(%ToolUse{}, &1))
  |> Enum.map(fn tu ->
    result = MyApp.execute_manually(tu.name, tu.input)
    ToolResult.new(tool_use_id: tu.id, name: tu.name, content: result)
  end)

  {:continue, results, state}
end
```

**Asynchronous** — stop, handle externally, then resume via `prompt/3`:

```elixir
# In handle_stop: save the tool use info and stop
def handle_stop(%{stop_reason: :tool_use} = response, state) do
  tool_use = find_tool_use(response, "needs_human_review")
  {:stop, %{state | private: Map.put(state.private, :pending_tool, tool_use)}}
end

# Later, when the external work completes:
Agent.prompt(agent, [
  ToolResult.new(tool_use_id: id, name: "needs_human_review", content: result)
])
```

Both work because `{:continue, content, state}` and `prompt/3` accept the same content types — a string (wrapped in `Text`) or a list of content blocks (which can include `ToolResult` blocks).

### Steps and turns

The agent's loop has two conceptual levels:

- **Step** -- a single LLM request-response cycle. If the model responds with tool use blocks, the agent handles them and makes a new request with the tool results. Each request-response is one step.
- **Turn** -- a complete unit of work ending when the model responds without calling tools (stop reason `:stop`, `:length`, etc.). A turn may contain one or more steps. Turns are implicit — the boundary where `handle_stop` fires — not tracked by the framework.

A prompt round may yield one or more turns (when `handle_stop` returns `{:continue, ...}`), and each turn may yield one or more steps:

```
prompt round
  └── turn 1
  │     ├── step 1 → tool_use → execute tools
  │     ├── step 2 → tool_use → execute tools
  │     └── step 3 → :stop (turn complete, handle_stop fires)
  │         → handle_stop returns {:continue, "keep going"}
  └── turn 2
  │     └── step 1 → :stop (turn complete, handle_stop fires)
  │         → handle_stop returns {:continue, "keep going"}
  └── turn 3
        ├── step 1 → tool_use → execute tools
        └── step 2 → :stop (turn complete, handle_stop fires)
            → handle_stop returns {:stop, state} → done
```

### max_steps

A single `max_steps` option (default `:infinity`) caps the total number of LLM requests across the entire prompt round. The step counter resets when a new prompt round begins (i.e. when `prompt/3` is called on an idle agent). The `max_steps` default lives in `opts`; per-prompt overrides via `prompt/3` are ephemeral (they apply only to that round).

```elixir
# Set at agent level (default for all prompt rounds)
MyAgent.start_link(model: ..., opts: [max_steps: 30])

# Override per prompt (this round only, does not change the default)
Agent.prompt(agent, "Do exhaustive research", max_steps: 50)
```

`max_steps` is a safety net, not the primary control mechanism. It catches two failure modes:

- **Runaway tool loops** -- the model calls tools in circles within a single turn, never producing a text response. Steps accumulate, limit is hit.
- **Runaway continuation** -- `handle_stop` keeps returning `{:continue, ...}`. Each turn burns steps, limit is eventually hit.

When hit: `handle_stop` still fires (for bookkeeping), but if it returns `{:continue, ...}`, the agent overrides the decision and stops. The listener receives `{:done, response}` as normal.

There is no separate `max_turns` option. External control covers turn-level intervention:

- `Agent.cancel/1` -- hard stop with rollback
- `Agent.prompt/3` -- steering at the next turn boundary ("stop what you're doing")
- User-defined turn tracking in `private` via `handle_stop` for custom policies

The `state.step` counter is visible to all callbacks, so users can make decisions based on it (e.g. reject tools after a threshold in `handle_tool_call`).

---

## Pause and resume

Pause exists for exactly one purpose: **tool call approval**. Only `handle_tool_call` can return `{:pause, state}`. No other callback pauses.

When `handle_tool_call` returns `{:pause, state}`:

- The agent's status becomes `:paused`
- The agent sends `{:agent, pid, :pause, tool_use}` to the listener
- The agent waits for `Agent.resume/2`
- `prompt/3` stages the content as a pending prompt (same as when running)

```elixir
Agent.resume(agent, :approve)              # approve the tool, continue processing
Agent.resume(agent, {:reject, reason})     # reject with error result
```

On `:approve`, the GenServer continues collecting decisions for remaining tools. On `{:reject, reason}`, the tool gets an error `ToolResult` and the GenServer continues with the next tool. Once all decisions are collected, approved tools execute in parallel.

Other callbacks do not need pause:

- **`handle_stop`**: returns `{:stop, state}` or `{:continue, prompt, state}`. If the human needs to decide, the agent stops and the human sends a new `prompt/3`. No functional difference from pausing — the agent is idle, waiting for input.
- **`handle_error`**: returns `{:stop, state}` or `{:retry, state}`. Same reasoning — stop and let the human re-prompt if needed.
- **`handle_tool_result`**: returns `{:ok, result, state}`. If result review is needed, the callback can modify the result synchronously. Pausing here was niche and added complexity.

---

## Prompt queuing (steering)

When the agent is running (autonomously looping), the caller can steer it by sending a new prompt:

```elixir
# Agent is looping autonomously...
:ok = Agent.prompt(agent, "Stop what you're doing, focus on X instead")
```

The prompt is **staged** as a pending prompt. At the next turn boundary (after the current turn completes):

- `handle_stop` fires as normal (for bookkeeping, state updates, etc.)
- Regardless of `handle_stop`'s return value, the staged prompt overrides the decision
- If `handle_stop` returned `{:stop, state}`, the staged prompt continues the loop instead
- If `handle_stop` returned `{:continue, callback_prompt, state}`, the staged prompt replaces `callback_prompt`

The staged prompt becomes the next user message. Calling `prompt/3` again while running replaces the staged prompt — last-one-wins. The caller is assumed to be the same entity updating its intent; there is no notification when a staged prompt is replaced.

This replaces the need for a separate `Agent.pause/1` function. External intervention is just sending a prompt — the same API the caller already uses.

---

## Context management

### Lazy tree updates

The agent does not commit messages to the tree until a prompt round completes successfully. During the loop, in-progress messages (the user's prompt, assistant responses, tool results) are tracked in `server.pending_messages`. A transient `%Context{}` is built on demand for each step via `build_context/1`, combining `MessageTree.messages(state.tree)` with `pending_messages`.

- `state.tree` = the committed conversation tree, only updated atomically on completion
- Step Tasks receive a transient `%Context{}` built from tree messages + pending messages
- On `:done`: `MessageTree.push(tree, pending_messages, pending_usage)` commits the round
- On cancel: pending messages and pending usage are discarded, tree unchanged

This means the tree is always in a consistent state — no orphaned tool use blocks, no consecutive user messages, no partial turns.

### Cancel semantics

`Agent.cancel/1` aborts the current operation:

1. Kills any running Step/Executor/Tool Tasks
2. Discards all pending messages and pending usage
3. Tree is unchanged — only committed rounds persist
4. Agent returns to `:idle`
5. Listener receives `{:agent, pid, :cancelled, nil}`

Cancel works at any point during the loop — mid-stream, mid-tool-execution, mid-callback — and always produces a clean state. No special handling needed per cancellation point.

---

## What users build on top

The agent provides mechanism; users provide policy:

| Omni.Agent provides | Users build on top |
|---|---|
| Stateful conversation process | Domain-specific system prompts |
| Dynamic tool management | Which tools to give the agent when |
| Outer loop with continuation callbacks | Goal evaluation logic |
| Pause/resume mechanism | Approval UIs, human-in-the-loop flows |
| Process lifecycle (supervised, named) | Multi-agent orchestration |
| Streaming events to caller | UI layer, logging, metrics |
| Error handling callbacks | Retry strategies, fallback logic |
| | Task decomposition / planning |
| | Memory / RAG integration |
| | Agent-to-agent communication |

Task planning (splitting work into subtasks, maintaining a task list) is application logic. The agent provides the loop and the hooks; the user provides a `create_plan` tool and a system prompt that tells the model how to use it. The planning behaviour emerges from the LLM's reasoning, not from framework code.

---

## Module layout

```
lib/omni/
├── agent.ex                    # Public module: behaviour, use macro, callback defaults, API
├── agent/
│   ├── state.ex                # %State{} struct (@moduledoc false)
│   ├── server.ex               # Internal GenServer: handle_call, handle_info, state machine,
│   │                            # step spawning, tool decision/execution, event forwarding (@moduledoc false)
│   ├── step.ex                  # Step process: streams LLM request, forwards events via
│   │                            # tagged ref (@moduledoc false)
│   └── executor.ex              # Executor process: spawns Tool.Runner.run in a linked Task,
│                                # sends results back via tagged ref (@moduledoc false)
├── tool.ex                      # Tool struct, behaviour, use macro, execute/2
├── tool/
│   └── runner.ex                # Parallel tool execution: ToolUse blocks → ToolResult blocks
```

`agent.ex` is what users interact with — `use Omni.Agent`, callback definitions, and public API functions (thin `GenServer.call` wrappers). `agent/server.ex` is the internal GenServer — state transitions, task management, tool decision/execution phases, event routing. `agent/step.ex` encapsulates the streaming execution logic — it uses `Task.start_link/1` to spawn a linked process that consumes a `StreamingResponse` and sends ref-tagged messages back to the GenServer. `agent/executor.ex` is a thin Task wrapper that calls `Tool.Runner.run/3` and sends results back via a tagged ref. This separates interface from implementation; the server, step, and executor modules are not part of the public API.

