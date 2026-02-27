# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Tool Calling Loop

**Status:** Implemented. See `Omni.Loop` and the CLAUDE.md "Recursive stream loop" section for details.

---

## Structured Output

**Status:** Implemented. The `:output` option on `stream_text/3` / `generate_text/3` sends a JSON Schema to the provider for constrained decoding. `Omni.Loop` validates the response (JSON decode + Peri validation) and retries up to 3 times on failure. Each dialect handles wire format independently — see CLAUDE.md conventions for details.

---

## Agent

**Status:** Phase 1 implemented. See `context/agent.md` for the full design document.

`Omni.Agent` — a GenServer-based building block for stateful, long-running LLM interactions. Manages its own conversation context, communicates with callers via async process messages, and provides lifecycle callbacks for controlling continuation, tool execution, error handling, and human-in-the-loop flows. The agent bypasses `Omni.Loop`'s tool execution (calling `stream_text` with `max_steps: 1`) and manages its own loop with 6 lifecycle callbacks: `init`, `handle_tool_call`, `handle_tool_result`, `handle_stop`, `handle_error`, `terminate`.

Implementation is split into three phases. Each phase produces a testable, strictly more capable agent. All phases use `Req.Test.stub` for integration tests — no API keys required.

### Phase 1: State + GenServer skeleton + basic prompt/response cycle

**Status:** Implemented.

The foundation. A single-turn chatbot agent.

**Modules:**
- `Omni.Agent.State` — struct definition
- `Omni.Agent` — behaviour, `use` macro, callback defaults, public API (`GenServer.call` wrappers)
- `Omni.Agent.Server` — GenServer init, state machine, step spawning, event forwarding
- `Omni.Agent.Step` — step process (streams LLM request, forwards events via tagged ref)

**Scope:**
- Single-turn only: prompt in → stream events → `:done`
- Step process: calls `stream_text(max_steps: 1)`, enumerates SR, forwards events to GenServer via tagged ref
- Event forwarding to listener (SR pass-through events + agent-level `:done`, `:error`, `:cancelled`)
- Listener management: auto-set from first `prompt/3`, explicit `listen/2`
- Context management: lazy commit on completion, rollback on cancel
- Usage accumulation across prompt rounds
- Callbacks: `init/1`, `handle_stop/2` (default: `{:stop, state}`), `terminate/2`
- Public API: `start_link/1,2`, `prompt/3`, `cancel/1`, `clear/1`, `listen/2`, all getters

**Not in scope:** tool execution, continuation, pause/resume, prompt queuing (steering).

**Changes from design:**
- Step execution extracted into `Omni.Agent.Step` module (design had it inline in Server). Uses `Task.start_link/1` instead of `spawn_link` for automatic `$callers` propagation, which is needed for process-ownership registries (Req.Test, Mox) to work across the process chain.
- State struct uses `step_task: {pid, ref} | nil` instead of separate `step_ref` and `step_pid` fields — they are always set and cleared together.
- State struct includes `module` field to store the callback module (or nil for headless agents), enabling callback dispatch without closure capture.
- GenServer propagates `$callers` from `start_link` caller through init, since GenServer doesn't do this automatically (unlike Task). Required so the Step process's `$callers` chain reaches the originating process.
- GenServer traps exits (`Process.flag(:trap_exit, true)`) to handle step process termination on cancel without crashing.

### Phase 2: Tool execution

Adds the decision phase, parallel tool execution, and schema-only tool detection. Still single-turn — `handle_stop` always returns `{:stop, state}`.

**Scope:**
- Executor Task + Tool Tasks (parallel execution)
- `execute_many/3` shared utility (usable by both Agent and eventually Loop)
- Decision phase: `handle_tool_call/2` — `:execute`, `{:reject, reason}`, per tool
- Result phase: `handle_tool_result/3` — pass through or modify
- `:tool_result` events to listener
- Schema-only tool detection: skip decision phase, go straight to `handle_stop` with `stop_reason: :tool_use`
- Tool management: `add_tools/2`, `remove_tools/2` (idle only)
- Tool timeout handling (`:tool_timeout` option)

**Not in scope:** `{:pause, state}` from `handle_tool_call`, continuation, steering.

**Testable:** agent with tools, model calls tools, decisions collected, tools execute in parallel, results sent back as events, next step fires with tool results in context. Rejected tools produce error results. Schema-only tools reach `handle_stop` with `stop_reason: :tool_use`. Timed-out tools produce error results. Tool management while idle works, while running returns error.

### Phase 3: Continuation + pause/resume + steering

The outer loop. Turns the single-turn agent into a full autonomous agent.

**Scope:**
- `handle_stop` returning `{:continue, prompt, state}` — recursive loop
- `handle_error/2` with `{:retry, state}`
- Pause/resume: `handle_tool_call` returning `{:pause, state}`, `Agent.resume/2`
- Prompt queuing: `prompt/3` while running stages for next turn boundary
- `max_steps` enforcement (from `opts`, ephemeral per-prompt override via `prompt_opts`)
- `:turn` events at intermediate turn boundaries

**Testable:** autonomous agent looping through multiple turns via `{:continue, ...}`. Pause on tool call, resume with approve/reject. Steer running agent with queued prompt (overrides `handle_stop` decision). `max_steps` stops runaway loops. `:turn` events fire at intermediate boundaries, `:done` at the end. `handle_error` with `{:retry, state}` retries failed steps.

Target: v1.

---

## Pre-v1 Checklist

- **Agent** — Design and implement `Omni.Agent` (see above).
- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — Review all `@moduledoc`, `@doc`, and `@typedoc` annotations. Ensure top-level API functions have examples. Check ExDoc output.

---

## Future Work

- **Parallel tool execution in Omni.Loop** — `Omni.Loop.execute_tools/2` currently runs tools sequentially via `Enum.map`. A shared `execute_many/3` utility (using `Task.async` + `Task.yield_many`) is being built for `Omni.Agent` and can be adopted by Loop to give all `stream_text`/`generate_text` callers parallel tool execution for free. The utility handles per-tool timeouts and graceful failure. Follow-up after agent implementation.
- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_input_modalities`.
