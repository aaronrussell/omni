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

## Phase 3a — Dialects + Composition ✓

Dialect behaviour, Anthropic Messages dialect, and the Provider composition functions.

- Dialect behaviour (`option_schema/0`, `build_path/1`, `build_body/3`, `parse_event/1`)
- Anthropic Messages dialect — full body building (messages, system as content block, tools, attachments with image/PDF type dispatch, cache control) and event parsing (all SSE event types, stop reason normalization)
- `Provider.build_request/3` — composes dialect + provider into a `%Req.Request{}`
- `Provider.parse_event/2` — composes `adapt_event/1` → dialect `parse_event/1`
- Cache control support — `:short` / `:long` universal option, applied to system, last message content block, last tool
- Unit, mocked integration, and live tests for the full pipeline

## Phase 3b — Additional Dialects ✓

- OpenAI Completions dialect (now used by OpenRouter)
- OpenAI Responses dialect (used by OpenAI provider)
- Google Gemini dialect
- OpenRouter provider (Completions-based meta-provider)
- Fixed Completions `parse_event` clause ordering (OpenRouter sends `role` on every chunk)

## Phase 3c — Normalize Dialect Events

Simplify and normalize the dialect event contract before building StreamingResponse. The goal is a minimal, consistent set of delta tuples that all dialects emit, with StreamingResponse responsible for expanding them into the rich consumer-facing event vocabulary.

### 1. Refactor `parse_event` to return lists

Change `Dialect.parse_event/1` and `Provider.parse_event/2` from returning `{atom, map} | nil` to returning `[{atom, map}]`. This solves two problems:

- No more nils leaking through the pipeline requiring `Stream.reject` — empty list means "skip"
- Providers that bundle multiple signals in one SSE event (Google bundles text + finishReason + usage in every event) can emit multiple logical events from a single parse

Callers change from `Stream.map |> Stream.reject(&is_nil/1)` to `Stream.flat_map`. Mechanical refactor touching all dialects, `Provider.parse_event/2`, and all integration tests.

### 2. New delta format

Replace the current type-specific delta vocabulary with a minimal set of generic events:

```elixir
{:message, %{model: _, usage: _, stop_reason: _}}  # envelope/metadata accumulator
{:block_start, %{type: _, index: _, ...}}           # content block begins (carries id/name for tool_use)
{:block_delta, %{type: _, index: _, delta: _}}      # content fragment
{:error, %{reason: _}}                              # mid-stream error
```

**`:message`** — carries envelope metadata. May appear multiple times (start, middle, end) with partial data. StreamingResponse merges all `:message` maps into the response envelope. This naturally handles: usage bundled in done (Anthropic, Responses), usage as separate event (Completions), usage on every event (Google), model ID at start, stop_reason at end.

**`:block_start`** — begins a content block. Type is `:text`, `:tool_use`, or `:thinking`. For `:tool_use`, also carries `:id` and `:name`. Optional for `:text` and `:thinking` — StreamingResponse creates the block implicitly on first `:block_delta` if no explicit start was received.

**`:block_delta`** — content fragment. Type + index together identify the block. StreamingResponse accumulates: text concatenation for text/thinking, JSON fragment joining for tool_use.

**No `:stop` event** — stream termination is the transport signal. The presence of `stop_reason` in accumulated `:message` data tells StreamingResponse the model finished intentionally.

**No `_end` events** — StreamingResponse synthesizes block completion from stream termination. Consumer-facing `_end` events (`:text_end`, `:tool_use_end`, etc.) are emitted by StreamingResponse, not by dialects.

### 3. Thinking/reasoning option

Design and implement the `thinking` option across all dialects. Research needed for each provider's thinking/reasoning config:

- **Anthropic**: `thinking` config with `budget_tokens` — emits `thinking` content blocks
- **OpenAI Responses**: `reasoning` config with `summary` option — emits `response.reasoning_summary_text.delta` events
- **OpenAI Completions** (via OpenRouter): reasoning models include `reasoning`/`reasoning_details` in delta chunks
- **Google**: `thinkingConfig` with `thinkingBudget` — emits `thought` parts in content

Goal: unified `thinking` option (on/off or budget) that each dialect translates to its provider-specific config.

### 4. Fix Google Gemini event parsing

Google sends `modelVersion` and `usageMetadata` in every SSE event, and `finishReason` in the final event. Currently the dialect only emits `:text_delta` and drops the rest (model, usage, finish info). With the list return + new delta format, every Google event can emit `[{:message, %{...}}, {:block_delta, %{...}}]`, capturing all available data.

### 5. Expand live tests

Expand dialect live tests to cover three scenarios each, inspecting the actual delta tuples:

- **Simple text generation** (already done for all dialects)
- **Tool calling** — verify `:block_start` with tool id/name, `:block_delta` with JSON fragments, `:message` with `:tool_use` stop reason
- **Thinking/reasoning** — verify `:block_delta` with thinking content (requires thinking option from step 3)

This validates real API data against the normalized event contract and confirms StreamingResponse will have everything it needs (usage, stop reason, content) across all providers.

### Index semantics note

Anthropic uses global content block indices (text at 0, tool_use at 1). OpenAI uses per-type index namespaces (output_index for items, content_index for text within items). Dialects should emit indices as-is from their wire format. StreamingResponse identifies blocks by the `{type, index}` pair, so per-type indexing works naturally. The important thing is that within a single response, each `{type, index}` pair maps to exactly one content block.

### Suggested order

1. `parse_event` returns lists (mechanical, unblocks everything)
2. New delta format (refactor all `parse_event` implementations)
3. Fix Google event parsing (now possible with lists + new format)
4. Thinking option design + implementation
5. Expanded live tests (validates everything end-to-end)

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

1. **`build_body/3` return type** — Returns `{:ok, map()} | {:error, term()}` but no dialect currently validates or fails. Should it return a bare map? Depends on where validation ends up living. Defer to Phase 5 (`stream_text` orchestration).

2. **Where does validation live?** — Options, content blocks, and media types all need validation. Candidates: top-level API boundary (Peri schemas in `stream_text`/`generate_text`), inside `build_body/3`, or both. Currently `encode_content/1` will crash on unsupported attachment media types (no catch-all clause). Defer to Phase 5.

3. **Universal options location** — `max_tokens`, `temperature`, `cache`, `metadata`, and `thinking` are universal (apply to all providers). Where is the schema defined and how does it compose with dialect/provider schemas? Defer to Phase 5.

4. **Plain text attachment source** — Should `Attachment.source` support `{:text, content}` in addition to `{:base64, data}` and `{:url, url}`? Wait to see if multiple providers support it.

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **~~Mix task for models.dev import~~** — done (`mix models.get`).
- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Option schema composition** — exact merging strategy for Peri schemas (open question in design doc, resolve during phase 5).
- **~~`raw: true` plumbing~~** — resolved. Separating request building from execution means both `%Req.Request{}` and `%Req.Response{}` are naturally available. `StreamingResponse` holds them when `raw: true` is passed.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
