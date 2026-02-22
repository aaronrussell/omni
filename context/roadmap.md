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

- Dialect behaviour (`option_schema/0`, `handle_path/2`, `handle_body/3`, `handle_event/1`)
- Anthropic Messages dialect — full body building (messages, system as content block, tools, attachments with image/PDF type dispatch, cache control) and event parsing (all SSE event types, stop reason normalization)
- `Provider.build_request/3` — composes dialect + provider into a `%Req.Request{}`
- `Provider.parse_event/2` — composes `adapt_event/1` → dialect `handle_event/1`
- Cache control support — `:short` / `:long` universal option, applied to system, last message content block, last tool
- Unit, mocked integration, and live tests for the full pipeline

## Phase 3b — Additional Dialects ✓

- OpenAI Completions dialect (now used by OpenRouter)
- OpenAI Responses dialect (used by OpenAI provider)
- Google Gemini dialect
- OpenRouter provider (Completions-based meta-provider)
- Fixed Completions `handle_event` clause ordering (OpenRouter sends `role` on every chunk)

## Phase 3c — Normalize Dialect Events ✓

Simplified and normalized the dialect event contract. All dialects now emit a minimal, consistent set of delta tuples. StreamingResponse (Phase 4) will expand them into the rich consumer-facing event vocabulary.

**Delta format** — 4 generic event types: `:message` (envelope/metadata), `:block_start` (content block begins), `:block_delta` (content fragment), `:error` (mid-stream error). All dialects return `[{atom, map}]` lists; callers use `Stream.flat_map`.

**Thinking option** — unified `thinking: true | false | :none | :low | :medium | :high | :max | [effort: atom, budget: integer]` option. Each dialect translates to its wire format:

- **Anthropic**: Two paths — adaptive (4.6 models: `"type" => "adaptive"` + `output_config`) and manual (older: `"type" => "enabled"` + `budget_tokens`, auto-adjusts `max_tokens`). Drops temperature when active. `false`/`:none` → `"disabled"`.
- **OpenAI Responses**: Sets `"reasoning"` with effort + `"summary" => "auto"`. Caps `:max` → `"high"`.
- **OpenAI Completions**: Sets `"reasoning_effort"` top-level. Preserves `:max` for provider adaptation.
- **Google Gemini**: Sets top-level `"thinkingConfig"` with `thinkingLevel` or `thinkingBudget` + `includeThoughts`. Caps `:max` → `"high"`.
- **OpenRouter**: `modify_body/2` converts `"reasoning_effort"` → `"reasoning"` object, maps `"max"` → `"xhigh"`.

**Parse events for thinking**: Completions parses `reasoning_content` deltas, Gemini parses `"thought" => true` parts. Both emit `{:block_delta, %{type: :thinking, ...}}`.

**Dialect unit tests** — all 4 dialects have `handle_event/1` and `handle_body/3` unit tests. Integration tests live at the top level (see Phase 5).

### Index semantics note

Anthropic uses global content block indices (text at 0, tool_use at 1). OpenAI Responses has three index namespaces (`output_index`, `content_index`, `summary_index`) — all dialects now normalize to `output_index` (the global position in the response's `output[]` array) so block ordering is consistent. StreamingResponse identifies blocks by `{type, index}` pairs.

---

## Phase 4 — StreamingResponse ✓

Consumer-facing streaming layer. `StreamingResponse` wraps the delta stream from Phase 3c, accumulates a partial `%Response{}`, and yields rich typed events via `Enumerable`.

- `new/2` — takes raw delta events + keyword opts (`model`, `cancel`, `raw`), builds the full consumer event pipeline at construction time via `Stream.transform/5`
- `Enumerable` protocol — delegates directly to the pre-built pipeline on the struct, yields `{event_type, event_map, partial_response}` three-element tuples
- `text_stream/1` — stream of text delta binaries only
- `complete/1` — consumes stream via `Enum.at/2`, returns `{:ok, Response.t()} | {:error, term()}`
- `cancel/1` — invokes opaque cancel function (passed in at construction, no Req dependency)

**Struct:** Two fields only — `stream` (the pre-built consumer event pipeline) and `cancel` (zero-arity function or nil). Model and raw are baked into the `Stream.transform/5` accumulator closure at construction time, not stored on the struct.

**Pipeline:** Uses `Stream.transform/5` with `last_fun` for finalization (replaces synthetic `:__finalize__` sentinel). `last_fun` emits block `_end` events always; `:done` only on success (no `:done` after `:error`).

**Consumer events:** Per-type lifecycle atoms (`text_start/delta/end`, `thinking_start/delta/end`, `tool_use_start/delta/end`) plus `:error` and `:done`. `_end` events carry `content: %ContentBlock{}` (fully built struct). `_start` events are synthesized for text/thinking if not explicitly received. `:done` is a success-only terminal event; `:error` is the terminal event on failure.

**Accumulation:** Text/thinking parts collected as iodata (prepend + reverse). Tool use JSON fragments assembled and parsed on finalization (graceful fallback to `%{}` on decode failure). Google complete-input tool_use (`:input` on `:block_start`) bypasses JSON assembly. Signatures, redacted thinking, and Message.private all accumulated correctly.

**Stop reason inference:** At finalization, `infer_stop_reason/1` checks accumulated blocks — if tool_use blocks exist, the stop reason is `:tool_use` regardless of what the dialect reported. This handles Google (which sends `finishReason: "STOP"` even for function calls, sometimes split across separate SSE events from the function call itself).

**Usage computation:** String-keyed token counts from `:message` events mapped to `%Usage{}` with costs derived from `%Model{}` pricing fields.

**HTTP execution:** StreamingResponse does not execute HTTP requests. The caller (`stream_text` in Phase 5) executes the request, composes the SSE + event pipeline, and passes the resulting delta stream into `new/2`. StreamingResponse is provider/dialect/HTTP-agnostic.

**Tests:** Unit tests use `new/2` with scripted delta lists for all cases (block lifecycle, redacted thinking, signatures, Google complete-input, errors, partial responses, cancel, raw pass-through). Integration tests deferred to Phase 5 `stream_text`.

---

## Phase 5 — Top-Level Orchestration ✓

Wiring everything together. Mostly composition of tested parts.

**Build:**
- `Omni.stream_text/3` — model resolution, context coercion, request building and execution, lazy event stream composition, StreamingResponse wrapping
- `Omni.generate_text/3` — built on `stream_text` + `complete/1`
- HTTP error handling — non-200 status detection and error body reading

**Test:** Integration tests (`test/integration/`) exercise `generate_text` and `stream_text` through the full stack per provider (text, tool use, thinking, streaming). Error tests cover HTTP errors (401/429/500), mid-stream SSE errors (synthetic fixture), auth failures, model resolution errors, context coercion, and stream features (cancel, raw). Live tests (`test/live/`) make real API calls per provider. All use `Omni.get_model/2` for model resolution.

---

## Phase 5b — Refactor: Callbacks, Orchestration, Validation

Cleans up deferred design decisions from Phase 5. Three sub-phases, each independently shippable. See `context/refactor.md` for full details.

### Phase 5b-A — Rename Callbacks + Simplify Signatures ✓

Mechanical renames across the codebase. No logic changes.

- Dialect: `build_path` → `handle_path/2`, `build_body` → `handle_body`, `parse_event` → `handle_event`
- Provider: `adapt_body` → `modify_body`
- `handle_body` returns bare `map()` instead of `{:ok, map()}`
- `handle_path` takes `(model, opts)` instead of just `(model)` for future extensibility
- Remove unused `option_schema/0` from Provider behaviour
- Update all implementations, callers, tests

### Phase 5b-B — Restructure Orchestration into Omni.Request ✗

Introduce `Omni.Request` module. Move orchestration from Provider into Request. Change event hook position.

- New `Omni.Request` module with public `build/3` and `stream/3`, plus `@doc false` `validate/2` and `parse_event/2` for testability
- Move `Provider.build_request/3`, `parse_event/2`, `new_request/4` logic into `Omni.Request`
- `Omni.stream_text/3` becomes a thin wrapper: pop `:raw`, call `Request.build`, call `Request.stream`
- Replace pre-dialect `adapt_event/1` with post-dialect `modify_events/2` `([deltas], raw_event) → [deltas]`
- `validate/2` pops config keys, three-tier merges them, returns a unified opts map (config + inference combined)
- All callbacks (`build_url`, `authenticate`, `handle_body`, `modify_body`) receive the unified opts map
- Change `build_url/2` to receive `(path, opts)` instead of `(base_url, path)`
- Change `authenticate/2` to receive unified opts map instead of keyword list
- Three-tier config merge extended to `base_url` and `headers` (not just `api_key`)

### Phase 5b-C — Option Validation + Timeout ✗

Add validation and switch opts from keyword list to validated map.

- Define universal option schema as module attribute on `Omni.Request` (`max_tokens`, `temperature`, `timeout`, `cache`, `metadata`, `thinking`)
- `:timeout` defaults to 300,000ms (5 minutes) — maps to Req's `receive_timeout`. Req's 15s default is far too low for LLMs.
- `validate/2` gains Peri validation: pops config/framework keys, validates inference opts (strict mode catches typos), three-tier merges config, returns unified map with defaults
- Result is a map with defaults filled in — all downstream callbacks receive map, not keyword list
- No `:req_opts` escape hatch — YAGNI, trivial to add later
- Update all `handle_body`/`modify_body` implementations to use map access
- Implement actual Peri schemas in dialect `option_schema/0` callbacks

---

## Resolved Open Questions

1. **~~`build_body/3` return type~~** — Resolved: returns bare `map()`. Validation happens at the API boundary before `handle_body` is called. (Phase 5b-A)

2. **~~Where does validation live?~~** — Resolved: at the `stream_text` API boundary. Universal schema + dialect `option_schema()` merged and validated via Peri once, before any callbacks. (Phase 5b-C)

3. **~~Universal options location~~** — Resolved: module attribute in `Omni`. Covers `max_tokens`, `temperature`, `cache`, `metadata`, `thinking`. (Phase 5b-C)

4. **Plain text attachment source** — Should `Attachment.source` support `{:text, content}` in addition to `{:base64, data}` and `{:url, url}`? Wait to see if multiple providers support it.

5. **StreamingResponse consumption patterns** — Explore how consumers will use StreamingResponse in practice. Key scenario: a consumer may want to process structured events (tool_use_start, thinking, etc.) AND simultaneously feed a text stream to the UI. Does the current single-enumerable API support this, or do we need something like tee/fork/broadcast?

6. **~~OpenRouter `reasoning_details` / provider event hook~~** — Resolved: post-dialect `modify_events/2` replaces pre-dialect `adapt_event/1`. The provider receives parsed deltas + raw event, can augment with provider-specific data. (Phase 5b-B)

---

## Deferred Work

Not part of initial implementation, but noted in the design:

- **~~Mix task for models.dev import~~** — done (`mix models.get`).
- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **~~Option schema composition~~** — resolved in Phase 5b-C.
- **~~`raw: true` plumbing~~** — resolved. Separating request building from execution means both `%Req.Request{}` and `%Req.Response{}` are naturally available. `StreamingResponse` holds them when `raw: true` is passed.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
