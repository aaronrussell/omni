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

**Status:** All phases implemented. See `context/agent.md` for the full design document.

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

**Status:** Implemented.

Adds the decision phase, parallel tool execution, and schema-only tool detection. Still single-turn — `handle_stop` always returns `{:stop, state}`.

**Modules:**
- `Omni.Tool.Runner` — shared parallel tool execution utility (`run/3`), used by both Agent and Loop
- `Omni.Agent.Executor` — thin Task wrapper that calls `Tool.Runner.run/3` and sends results via tagged ref

**Scope:**
- Executor Task + Tool Tasks (parallel execution via `Tool.Runner.run/3`)
- Decision phase: `handle_tool_call/2` — `:execute`, `{:reject, reason}`, per tool
- Result phase: `handle_tool_result/2` — pass through or modify
- `:tool_result` events to listener
- Schema-only tool detection: skip decision phase, go straight to `handle_stop` with `stop_reason: :tool_use`
- Tool management: `add_tools/2`, `remove_tools/2` (idle only)
- Tool timeout handling (`:tool_timeout` option)

**Not in scope:** `{:pause, state}` from `handle_tool_call`, continuation, steering.

**Changes from design:**
- `execute_many/3` became `Omni.Tool.Runner.run/3` — a separate module rather than a function on `Omni.Tool`. This keeps `Tool` as a low-level primitive (`new/1`, `execute/2`) while `Tool.Runner` handles content-block-level orchestration (ToolUse → ToolResult). Both Agent and Loop use it.
- `handle_tool_result` is arity 2, not 3. The `ToolResult` struct already carries `tool_use_id` and `name`, making the separate `ToolUse` argument redundant.
- `executor_ref` on State became `executor_task: {pid, ref} | nil` — mirrors `step_task` pattern, tracks both pid and ref together.
- State also carries `rejected_results: [ToolResult.t()]` for stashing rejected tool results during the decision phase (merged with executor results when execution completes).
- `Omni.Loop` was updated to use `Tool.Runner.run/3`, replacing its inline sequential tool execution with parallel execution.

### Phase 3: Continuation + pause/resume + steering

**Status:** Implemented.

The outer loop. Turns the single-turn agent into a full autonomous agent.

**Scope:**
- `handle_stop` returning `{:continue, prompt, state}` — recursive loop
- `handle_error/2` with `{:retry, state}`
- Pause/resume: `handle_tool_call` returning `{:pause, state}`, `Agent.resume/2`
- Prompt queuing: `prompt/3` while running stages for next turn boundary
- `max_steps` enforcement (from `opts`, ephemeral per-prompt override via `prompt_opts`)
- `:turn` events at intermediate turn boundaries

**Changes from design:**
- The `pending_prompt` field stores content only (not opts) — inference parameters from the original prompt round stay active.
- `handle_call` catch-all for mutating ops (add_tools, remove_tools, listen, clear) uses a single pattern matching clause that covers both `:running` and `:paused` statuses, returning `{:error, :running}` for backward compatibility.
- `cancel` now accepts both `:running` and `:paused` statuses via guard clause.
- `process_next_tool_decision` is recursive (not `Enum.reduce`) to support interruption via `{:pause, state}`.

---

## Pre-v1 Checklist

- **Agent** — Design and implement `Omni.Agent` (see above).
- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — Review all `@moduledoc`, `@doc`, and `@typedoc` annotations. Ensure top-level API functions have examples. Check ExDoc output.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_input_modalities`.
