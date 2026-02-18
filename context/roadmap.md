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

The authenticated HTTP layer, model loading, and SSE parser. First phase with real IO. Everything in this phase is testable without dialects — providers are built with stubbed dialect references, and integration tests use hand-built native request bodies.

**Done:**
- Provider behaviour + `use Omni.Provider` macro (`dialect/0`, all default callbacks)
- Auth resolution (`resolve_auth/1` — literal, `{:system, env}`, MFA, nil)
- `load_models/2` (JSON → Model structs, app-aware path resolution)
- Model JSON files in `priv/models/` (full catalogs via `mix models.get`, with modality filtering)
- `stream/4` stub (to be replaced by `new_request/4`)

**Build:**
- SSE parser (framing, buffering, `[DONE]` detection, JSON decoding, `SSE.stream/1` for lazy composition)
- `Provider.new_request/4` — builds an authenticated `%Req.Request{}` from raw provider params (path, body, opts). Replaces the `stream/4` stub.
- Concrete provider: Anthropic (with stubbed dialect reference)
- `Omni.Application` — loads providers into `:persistent_term` at startup
- `Omni.get_model/2` lookup function

**Test:** URL building, `authenticate/2`, model loading and lookup from `:persistent_term`. Integration tests: call `Provider.new_request/4` with hand-built native request bodies, execute with `Req.request/1`, and consume the async response body through the SSE parser — verify decoded JSON events come back. No dialects involved.

**Why this order:** The SSE parser is needed here (not deferred) to meaningfully test the streaming path. Real HTTP calls also provide ground-truth payloads for dialect testing in phase 3.

**Note:** This is where test infrastructure decisions happen — API key fixtures, recorded responses for CI, timeout handling.

---

## Phase 3 — Dialects + Composition

Dialect implementations and the Provider functions that compose across the dialect boundary. Dialects themselves are pure data transformation (no HTTP, no processes), but this phase also adds the composition layer that ties dialects to providers.

**Build:**
- Dialect behaviour (`option_schema/0`, `build_path/1`, `build_body/3`, `parse_event/1`)
- Anthropic Messages dialect
- OpenAI Completions dialect
- `Provider.build_request/3` — builds a `%Req.Request{}` from Omni types (model, context, opts) via dialect + provider, delegates to `new_request/4`
- `Provider.parse_event/2` — composes `adapt_event/1` and dialect `parse_event/1` into normalised deltas

**Test:** `build_body/3` — give it Model + Context + opts, assert output matches provider's expected JSON. `parse_event/1` — give it decoded JSON event maps (captured from phase 2 integration tests), assert correct delta tuples. `build_path/1` — trivial. `build_request/3` — assert the built `%Req.Request{}` has the correct URL, body, and auth for given Omni types. `parse_event/2` — assert full adapt + parse pipeline produces correct deltas. Dozens of pure unit tests per dialect.

**Why after phase 2:** Real SSE event payloads from phase 2 integration tests become test fixtures for `parse_event/1`. Real native request bodies that worked in phase 2 become the reference for `build_body/3` output. Phase 2 gives ground truth that phase 3 builds against.

---

## Phase 4 — StreamingResponse

Accumulation logic and the Enumerable contract. Simpler than originally planned — Req's `into: :self` eliminates the need for a spawned process and its lifecycle management.

**Build:**
- StreamingResponse struct (`events`, `resp`, `req`, `model`)
- `Enumerable` protocol implementation (drive the lazy event stream, accumulate partial Response, yield three-element consumer tuples)
- Accumulation logic: text concatenation, tool use JSON assembly, content block building
- `complete/1` — consume stream into final `%Response{}`
- `cancel/1` — delegates to `Req.cancel_async_response/1`

**Test:** Build a mock lazy stream of scripted delta tuple sequences, wrap in StreamingResponse, assert the enumerable yields correct consumer events with correctly accumulated partial responses. Test cancellation and mid-stream error events. All testable without HTTP, providers, or dialects — just feed it a list or stream of delta tuples.

**Note:** The main complexity here is the accumulation logic — correctly building up content blocks from deltas, especially tool use JSON assembly. The process lifecycle complexity from the original design has been eliminated by using Req's async mode.

---

## Phase 5 — Top-Level Orchestration

Wiring everything together. Mostly composition of tested parts.

**Build:**
- `Omni.stream_text/3` — model resolution, context coercion, config merging, option validation, request building and execution, lazy event stream composition, StreamingResponse wrapping
- `Omni.generate_text/3` — built on `stream_text` + `complete/1`
- `merge_config/2` — priority chain (call-time > app config > provider defaults)
- Option schema merging and Peri validation
- HTTP error handling — non-200 status detection and error body reading

**Test:** End-to-end integration: `Omni.generate_text({:anthropic, "claude-sonnet-4-20250514"}, "Hello")` returns a proper `%Response{}`. Tool use round-trips. Streaming to console. Error cases (bad model, invalid options, auth failure, non-200 responses). Option validation error messages.

**Why last:** Everything this phase calls already exists and is tested. The new logic is config merging, schema composition, and the orchestration pipeline — all relatively thin composition of tested parts.

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **Mix task for models.dev import** — automates populating `priv/models/*.json`. Hand-authored files are sufficient to start.
- **Additional providers** — Groq, Together, Fireworks, OpenRouter, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Additional dialects** — Google Gemini, OpenAI Responses. Add as needed.
- **Option schema composition** — exact merging strategy for Peri schemas (open question in design doc, resolve during phase 5).
- **~~`raw: true` plumbing~~** — resolved. Separating request building from execution means both `%Req.Request{}` and `%Req.Response{}` are naturally available. `StreamingResponse` holds them when `raw: true` is passed.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
