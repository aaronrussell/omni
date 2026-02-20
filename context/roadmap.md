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

## Phase 3c — Normalize Dialect Events ✓

Simplified and normalized the dialect event contract. All dialects now emit a minimal, consistent set of delta tuples. StreamingResponse (Phase 4) will expand them into the rich consumer-facing event vocabulary.

**Delta format** — 4 generic event types: `:message` (envelope/metadata), `:block_start` (content block begins), `:block_delta` (content fragment), `:error` (mid-stream error). All dialects return `[{atom, map}]` lists; callers use `Stream.flat_map`.

**Thinking option** — unified `thinking: true | false | :none | :low | :medium | :high | :max | [effort: atom, budget: integer]` option. Each dialect translates to its wire format:

- **Anthropic**: Two paths — adaptive (4.6 models: `"type" => "adaptive"` + `output_config`) and manual (older: `"type" => "enabled"` + `budget_tokens`, auto-adjusts `max_tokens`). Drops temperature when active. `false`/`:none` → `"disabled"`.
- **OpenAI Responses**: Sets `"reasoning"` with effort + `"summary" => "auto"`. Caps `:max` → `"high"`.
- **OpenAI Completions**: Sets `"reasoning_effort"` top-level. Preserves `:max` for provider adaptation.
- **Google Gemini**: Sets top-level `"thinkingConfig"` with `thinkingLevel` or `thinkingBudget` + `includeThoughts`. Caps `:max` → `"high"`.
- **OpenRouter**: `adapt_body/2` converts `"reasoning_effort"` → `"reasoning"` object, maps `"max"` → `"xhigh"`.

**Parse events for thinking**: Completions parses `reasoning_content` deltas, Gemini parses `"thought" => true` parts. Both emit `{:block_delta, %{type: :thinking, ...}}`.

**Integration tests** — all 4 dialects now have text, tool use, and thinking fixture-based integration tests (12 total).

### Index semantics note

Anthropic uses global content block indices (text at 0, tool_use at 1). OpenAI uses per-type index namespaces (output_index for items, content_index for text within items). Dialects emit indices as-is. StreamingResponse identifies blocks by `{type, index}` pairs.

---

## Phase 4 — StreamingResponse

Accumulation logic and the Enumerable contract. Simpler than originally planned — Req's `into: :self` eliminates the need for a spawned process and its lifecycle management.

**Build:**
- StreamingResponse struct (`events`, `resp`, `req`, `model`)
- `Enumerable` protocol implementation (drive the lazy event stream, accumulate partial Response, yield three-element consumer tuples)
- Accumulation logic: text concatenation, tool use JSON assembly, thinking text concatenation, content block building
- `complete/1` — consume stream into final `%Response{}`
- `cancel/1` — delegates to `Req.cancel_async_response/1`

**Test:** Build a mock lazy stream of scripted delta tuple sequences, wrap in StreamingResponse, assert the enumerable yields correct consumer events with correctly accumulated partial responses. Test cancellation and mid-stream error events. All testable without HTTP, providers, or dialects — just feed it a list or stream of delta tuples.

**Notes from Phase 3c:**
- The accumulation logic must handle 3 block types: `:text` (concatenate deltas), `:tool_use` (join JSON fragments, parse on completion), and `:thinking` (concatenate deltas, build `%Thinking{}` content block).
- `:block_start` is optional for `:text` and `:thinking` — StreamingResponse should create blocks implicitly on first `:block_delta` if no explicit start was received. Required for `:tool_use` (carries `:id` and `:name`).
- `:message` events may appear multiple times with partial data — merge all into the response envelope. No explicit `:stop` event; `stop_reason` in accumulated message data signals intentional completion. Consumer-facing `_end` events are synthesized by StreamingResponse from stream termination, not emitted by dialects.
- Google sends function call args complete (as a map) in `:block_start`, not as streamed `:block_delta` JSON fragments. The `:block_start` for tool_use may carry an `:input` key with the full args map.
- `:block_delta` events may carry an optional `signature` key (with or without `delta`). The accumulator must check for `signature` and set it on the corresponding content block (`Thinking`, `Text`, or `ToolUse`). Anthropic sends `signature_delta` events; Google sends `thoughtSignature` on parts.
- `:block_start` for thinking may carry a `redacted_data` key (Anthropic `redacted_thinking`) — create `Thinking{text: nil, redacted_data: data}` with no subsequent deltas expected.
- `:block_start` for tool_use may carry a `signature` key (Google `thoughtSignature`) — set on `ToolUse.signature`.

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

3. **Universal options location** — `max_tokens`, `temperature`, `cache`, `metadata`, and `thinking` are universal (apply to all providers). Where is the schema defined and how does it compose with dialect/provider schemas? Defer to Phase 5. For `thinking` specifically: validate type (atom | keyword list), Anthropic temperature + thinking incompatibility (currently silently dropped — could warn or error), and budget minimum enforcement (Anthropic requires >= 1024).

4. **Plain text attachment source** — Should `Attachment.source` support `{:text, content}` in addition to `{:base64, data}` and `{:url, url}`? Wait to see if multiple providers support it.

---

5. **OpenRouter `reasoning_details` round-tripping** — OpenRouter extends the Completions wire format with a `reasoning_details` array on assistant messages for reasoning round-trips. Each streaming chunk carries `reasoning_details` alongside the `reasoning` text delta, containing typed objects: `reasoning.summary` (duplicates the visible reasoning text), `reasoning.encrypted` (opaque blob with `data`, `id`, `format` fields — needed for tool-calling flows), and `reasoning.text` (raw text with optional signature). The full array must be passed back unmodified on the assistant message in follow-up requests — ordering matters. This is distinct from direct OpenAI Chat Completions where reasoning is truly ephemeral (no field to send it back).

   **Decided approach:** Store in `Message.private` (a `%{}` map for provider-specific opaque round-trip data, named after Req's precedent). During streaming, `reasoning_details` arrives alongside thinking deltas — the provider emits it as `{:message, %{private: %{reasoning_details: [...]}}}` and StreamingResponse accumulates it onto the Message. During encoding, the provider reads from `message.private` and places it on the wire message body. Flat atom keys, no namespacing for now.

   **Provider hook gap:** The current `adapt_event/1` (pre-dialect, JSON→JSON) can't emit delta tuples, and the Completions dialect shouldn't know about `reasoning_details`. Need a **post-dialect provider hook** — `adapt_deltas/2` taking `(deltas, raw_event)` — so the provider can augment dialect output with additional tuples. This mirrors the encoding side where `adapt_body/2` augments dialect output. Default passes through unchanged. Note: `adapt_deltas` receiving the raw event may make `adapt_event` redundant — the provider could do all pre/post work in one place. Revisit when implementing.

   **Encoding side:** OpenRouter's `adapt_body/2` already handles provider-specific body transforms. It would pull `reasoning_details` from the Message's `private` map (accessed via content blocks or passed through) and place it on the assistant message. Exact mechanism TBD when multi-turn encoding is implemented.

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **~~Mix task for models.dev import~~** — done (`mix models.get`).
- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Option schema composition** — exact merging strategy for Peri schemas (open question in design doc, resolve during phase 5).
- **~~`raw: true` plumbing~~** — resolved. Separating request building from execution means both `%Req.Request{}` and `%Req.Response{}` are naturally available. `StreamingResponse` holds them when `raw: true` is passed.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
