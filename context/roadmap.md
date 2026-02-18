# Omni Implementation Roadmap

**Last updated:** February 2026

---

## Phase 1 — Data Structures ✓

All structs in the library, done in one pass. Pure data, no IO, no processes.

- Content blocks: Text, Thinking, Attachment, ToolUse, ToolResult
- Message (with `new/1` constructor and lazy timestamp)
- Context (with `to_context` coercion from string/list/struct)
- Tool struct + `use Omni.Tool` behaviour/macro + `Tool.execute/2`
- Tool.Schema builder functions (object, string, number, enum, etc.)
- Model struct
- Response struct
- Usage struct (with `add/2` for accumulation)

---

## Phase 2 — Provider Infrastructure ✓

The authenticated HTTP layer, model loading, and SSE parser. First phase with real IO.

- Provider behaviour + `use Omni.Provider` macro (`dialect/0`, all default callbacks)
- Auth resolution (`resolve_auth/1` — literal, `{:system, env}`, MFA, nil)
- Three-tier API key resolution: call-site opt → app config → provider config default
- `load_models/2` (JSON → Model structs, app-aware path resolution)
- Model JSON files in `priv/models/` (full catalogs via `mix models.get`, with modality filtering)
- SSE parser (`Omni.SSE.stream/1` — framing, buffering, `[DONE]` detection, JSON decoding)
- `Provider.new_request/4` — builds an authenticated `%Req.Request{}` without executing
- Concrete provider: Anthropic (with stubbed dialect reference)
- `Omni.Application` — loads configured providers into `:persistent_term` at startup
- `Omni.get_model/2` and `Omni.list_models/1` lookup functions
- Test infrastructure: Req.Test plug mocking, SSE fixture capture helper, live tests (`:live` tag)

---

## Phase 3 — Dialects + Composition ✓ (Anthropic)

Dialect behaviour, Anthropic Messages dialect, and the Provider composition functions. OpenAI and Google dialects deferred to Phase 3b.

**Done:**
- Dialect behaviour (`option_schema/0`, `build_path/1`, `build_body/3`, `parse_event/1`)
- Anthropic Messages dialect — full body building (messages, system as content block, tools, attachments with image/PDF type dispatch, cache control) and event parsing (all SSE event types, stop reason normalization)
- `Provider.build_request/3` — composes dialect + provider into a `%Req.Request{}`
- `Provider.parse_event/2` — composes `adapt_event/1` → dialect `parse_event/1`
- Cache control support — `:short` / `:long` universal option, applied to system, last message content block, last tool
- Unit, mocked integration, and live tests for the full pipeline

**Remaining (Phase 3b):**
- OpenAI Completions dialect
- Google Gemini dialect
- Implementing additional dialects will surface commonalities and resolve several open questions below

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

## Open Questions

To be resolved as we implement more providers/dialects (OpenAI, Google) and the top-level API:

1. **Stateful vs stateless `parse_event`** — Currently `parse_event/1` is stateless. `content_block_stop` emits generic `:content_block_end` because the dialect doesn't know which block type was at that index. StreamingResponse resolves this during accumulation. Alternative: `parse_event/2` with an accumulator threaded via `Stream.transform`. Revisit after more providers — do they all have this ambiguity, or is it Anthropic-specific?

2. **`build_body/3` return type** — Returns `{:ok, map()} | {:error, term()}` but no dialect currently validates or fails. Should it return a bare map? Depends on where validation ends up living.

3. **Where does validation live?** — Options, content blocks, and media types all need validation. Candidates: top-level API boundary (Peri schemas in `stream_text`/`generate_text`), inside `build_body/3`, or both. Currently `encode_content/1` will crash on unsupported attachment media types (no catch-all clause) — this needs to be caught somewhere upstream.

4. **Universal options location** — `max_tokens`, `temperature`, `cache`, `metadata`, and `thinking` are universal (apply to all providers). Where is the schema defined and how does it compose with dialect/provider schemas?

5. **Thinking budgets** — How to handle extended thinking configuration (budget tokens, etc.) as a universal option. Needs research across providers.

6. **Plain text attachment source** — Should `Attachment.source` support `{:text, content}` in addition to `{:base64, data}` and `{:url, url}`? Depends on whether other providers support plain text document sources.

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **~~Mix task for models.dev import~~** — done (`mix models.get`).
- **Additional providers** — Groq, Together, Fireworks, OpenRouter, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Additional dialects** — Google Gemini, OpenAI Responses. Add as needed.
- **Option schema composition** — exact merging strategy for Peri schemas (open question in design doc, resolve during phase 5).
- **~~`raw: true` plumbing~~** — resolved. Separating request building from execution means both `%Req.Request{}` and `%Req.Response{}` are naturally available. `StreamingResponse` holds them when `raw: true` is passed.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
