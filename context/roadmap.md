# Omni Implementation Roadmap

**Last updated:** February 2026

---

## Phase 1 — Data Structures

All structs in the library, done in one pass. Pure data, no IO, no processes.

**Build:**
- Content blocks: Text, Thinking, Attachment, ToolUse, ToolResult
- Message (with `new/1` constructor and lazy timestamp)
- Context (with `to_context` coercion from string/list/struct)
- Tool struct + `use Omni.Tool` behaviour/macro + `Tool.execute/2`
- Tool.Schema builder functions (object, string, number, enum, etc.)
- Model struct
- Response struct
- Usage struct (with `add/2` for accumulation)

**Test:** Constructors, field validation, schema builder output, `Usage.add/2`, `to_context` coercion, `Message.new/1` timestamps. All unit tests, no dependencies.

**Why first:** Every subsequent phase uses these types. Having real structs from day one means no placeholder maps that need replacing later.

---

## Phase 2 — Provider Infrastructure

The authenticated HTTP layer, model loading, and SSE parser. First phase with real IO.

**Build:**
- Provider behaviour + `use Omni.Provider` macro (generates `dialect/0`, default callbacks)
- Auth module (key resolution with priority ordering, `{:system, ...}` and MFA support)
- SSE parser (framing, buffering, `[DONE]` detection, JSON decoding)
- Concrete providers: Anthropic + OpenAI (stubbing dialect references for now)
- Model JSON files in `priv/models/` (hand-author a few entries per provider)
- `Omni.Application` — loads providers into `:persistent_term` at startup
- `Omni.get_model/2` lookup function

**Test:** Auth resolution priority chain, URL building, `authenticate/2`, model loading and lookup from `:persistent_term`. Integration tests: call `Provider.stream/4` with hand-built native request bodies and an `:into` handler using the SSE parser — verify decoded JSON events come back. No dialects involved.

**Why this order:** The SSE parser is needed here (not deferred) to meaningfully test the streaming path. Real HTTP calls also provide ground-truth payloads for dialect testing in phase 3.

**Note:** This is where test infrastructure decisions happen — API key fixtures, recorded responses for CI, timeout handling.

---

## Phase 3 — Dialects

Pure data transformation. No HTTP, no processes.

**Build:**
- Dialect behaviour (`option_schema/0`, `build_path/1`, `build_body/3`, `parse_event/1`)
- Anthropic Messages dialect
- OpenAI Completions dialect

**Test:** `build_body/3` — give it Model + Context + opts, assert output matches provider's expected JSON. `parse_event/1` — give it decoded JSON event maps (captured from phase 2 integration tests), assert correct delta tuples. `build_path/1` — trivial. Dozens of pure unit tests per dialect.

**Why after phase 2:** Real SSE event payloads from phase 2 integration tests become test fixtures for `parse_event/1`. Real native request bodies that worked in phase 2 become the reference for `build_body/3` output. Phase 2 gives ground truth that phase 3 builds against.

---

## Phase 4 — StreamingResponse

Process machinery. The most mechanically complex phase.

**Build:**
- StreamingResponse struct (`pid`, `ref`)
- `Enumerable` protocol implementation (receive deltas, accumulate partial Response, yield three-element consumer tuples)
- Accumulation logic: text concatenation, tool call JSON assembly, content block building
- `complete/1` — consume stream into final `%Response{}`
- `cancel/1` — terminate the stream process
- Process lifecycle: bidirectional monitors, error propagation (`:DOWN` → error event)

**Test:** Spawn a mock process that sends scripted delta tuple sequences, assert the enumerable yields correct consumer events with correctly accumulated partial responses. Test cancellation, process crash → error event, caller death → stream self-terminates. All testable without HTTP, providers, or dialects.

**Note:** This phase will take longer than it looks. The process lifecycle, error propagation edge cases, and getting the `Enumerable` contract right needs iteration. Allocate extra time here.

---

## Phase 5 — Top-Level Orchestration

Wiring everything together. Mostly composition of tested parts.

**Build:**
- `Omni.stream_text/3` — model resolution, context coercion, config merging, option validation, pipeline composition
- `Omni.generate_text/3` — built on `stream_text` + `complete/1`
- `merge_config/2` — priority chain (call-time > app config > provider defaults)
- Option schema merging and Peri validation
- Stream handler composition (SSE parser → `adapt_event` → `parse_event` → send to caller)

**Test:** End-to-end integration: `Omni.generate_text({:anthropic, "claude-sonnet-4-20250514"}, "Hello")` returns a proper `%Response{}`. Tool use round-trips. Streaming to console. Error cases (bad model, invalid options, auth failure). Option validation error messages.

**Why last:** Everything this phase calls already exists and is tested. The new logic is config merging, schema composition, and the handler closure — all relatively thin orchestration.

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **Mix task for models.dev import** — automates populating `priv/models/*.json`. Hand-authored files are sufficient to start.
- **Additional providers** — Groq, Together, Fireworks, OpenRouter, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Additional dialects** — Google Gemini, OpenAI Responses. Add as needed.
- **Option schema composition** — exact merging strategy for Peri schemas (open question in design doc, resolve during phase 5).
- **`raw: true` plumbing** — capturing Req request/response from the streaming process (open question in design doc, resolve during phase 4/5).
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
