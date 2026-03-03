# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. It separates three concerns:

- **Models** — data structs describing a specific LLM (loaded from JSON in `priv/models/`)
- **Providers** — authenticated HTTP layer (where to send requests, how to authenticate)
- **Dialects** — wire format translation (how to build request bodies, parse streaming events)

The relationship: ~4-5 dialects, ~20-30 providers (each speaking one dialect), hundreds of models (each belonging to one provider). All requests are streaming-first; `generate_text` is built on top of `stream_text`.

See the [Context Documents](#context-documents) section for when and how to use the detailed design docs.

## Build & Development Commands

```bash
mix compile              # Compile the project
mix test                 # Run all tests
mix test --include live  # Run all tests including live API tests (needs API keys)
mix test path/to/test.exs           # Run a single test file
mix test path/to/test.exs:42       # Run a specific test (line number)
mix format               # Format all code
mix format --check-formatted       # Check formatting without changing files
mix models.get           # Fetch model data from models.dev into priv/models/
```

`mix models.get` fetches model catalogs from [models.dev](https://models.dev) for each provider listed in its `@providers` attribute. It filters out deprecated models and those without tool use support. The JSON files in `priv/models/` are checked into the repo — run this task manually when model data needs refreshing.

## Dependencies

- **Req** (`~> 0.5`) — HTTP client (used for streaming requests to LLM APIs)
- **Peri** (`~> 0.6`) — Schema-based validation (used for option validation)
- **ExDoc** (dev only) — Documentation generation
- **Plug** (test only) — Required for `Req.Test` plug-based mocking

## Architecture

### Key design patterns

- **Streaming-first**: Every LLM request uses streaming HTTP via Req's `into: :self` async mode. The event pipeline is composed as a lazy `Stream`: format parsing (SSE or NDJSON, selected by response content-type) → `Request.parse_event/2` (dialect `handle_event/1` + provider `modify_events/2`) → delta tuples. `parse_event` returns a list of `{type, map}` tuples (4 generic types: `:message`, `:block_start`, `:block_delta`, `:error`), so the pipeline uses `Stream.flat_map/2`. `StreamingResponse.new/2` takes raw delta events and keyword opts (`model`, `cancel`, `raw`), building the full consumer event pipeline at construction time via `Stream.transform/5`. The struct holds two fields: `stream` (the pipeline) and `cancel` (an opaque zero-arity function). Model and raw HTTP data are baked into the transform closure, not stored on the struct. Its `Enumerable` implementation delegates directly to the pipeline, yielding `{event_type, event_map, partial_response}` tuples. Key functions: `on/3` (register side-effect handler for an event type, returns new StreamingResponse — pipeline-composable), `text_stream/1` (stream of text delta binaries), `complete/1` (consume to final `%Response{}`), `cancel/1` (invoke cancel function). `Stream.transform/5`'s `last_fun` handles finalization — `:done` is only emitted on success, not after `:error`. No spawned process — Req/Finch manage the connection.

- **Models are data, not modules**: `%Model{}` structs are loaded from `priv/models/*.json` at startup into `:persistent_term` (keyed per provider). Models carry a direct module reference to their provider; the dialect is accessed via `provider.dialect()`.

- **Request building separated from execution**: `Request.build/3` takes Omni types (model, context, opts), validates options via Peri, and returns a `%Req.Request{}` via dialect + provider composition. `Request.stream/3` executes the request and returns a `StreamingResponse`. The dialect does heavy transformation (Omni types ↔ native JSON). The provider optionally modifies dialect output for service-specific quirks via `modify_body/3` (request body, context, opts) and `modify_events/2` (response).

- **Two message roles only**: `:user` and `:assistant`. No `:tool` role — tool results are `Content.ToolResult` blocks inside user messages. Role differences are expressed through content blocks, not message types.

- **Recursive stream loop**: `Omni.Loop` handles tool auto-execution and structured output validation via recursive `Stream.concat`. `stream_text/3` always delegates to `Loop.stream/5`. Each step's SR stream is wrapped to intercept `:done` (captured in process dictionary, suppressed from consumer). A lazy continuation thunk checks the captured response, executes tools in parallel via `Tool.Runner.run/3` if needed, emits synthetic `:tool_result` events, and either recursively builds the next step's stream or emits the final `:done` with aggregated `messages`/`usage`/`raw`. Single lazy pipeline — all SR infrastructure (`on/3`, `complete/1`, `text_stream/1`, `cancel/1`) works unchanged. `all_executable?/2` breaks the loop when any tool has a `nil` handler (schema-only), returning the response to the user for manual handling. Hallucinated tool names produce error `ToolResult`s sent back to the model. `:max_steps` option (default `:infinity`) caps rounds; `max_steps: 1` opts out of auto-looping. When `:output` is set, the loop validates the final response text against the schema (JSON decode + Schema validation) and retries up to 3 times on failure, skipping retry on `:length` stop reason. On success, `response.output` holds the validated/decoded map.

- **Single validation pass**: `Request.validate/2` merges the universal `@schema` (on `Omni.Request`) with `dialect.option_schema()`, does a three-tier config merge (provider config ← app config ← call-site opts), rejects unknown keys, and validates via Peri — all in one pass before any callbacks run. Config keys use `:any` type; inference keys are strictly typed. `:timeout` defaults to 300,000ms and maps to Req's `receive_timeout`.

### Module layout (target structure)

```
lib/omni.ex                         # Top-level API: generate_text, stream_text, get_model
lib/omni/
├── application.ex                  # Loads providers into :persistent_term at startup
├── model.ex                        # Model struct
├── context.ex                      # Context struct (system, messages, tools)
├── message.ex                      # Message struct (role, content blocks, timestamp)
├── response.ex                     # Response struct (wraps Message + metadata)
├── streaming_response.ex           # StreamingResponse + Enumerable impl
├── usage.ex                        # Usage struct (tokens + computed costs)
├── tool.ex                         # Tool struct, behaviour, use macro
├── tool/runner.ex                  # Parallel tool execution (ToolUse → ToolResult)
├── schema.ex                       # JSON Schema builders, validation, key normalization
├── content/{text,thinking,attachment,tool_use,tool_result}.ex
├── parsers/sse.ex                  # SSE stream parser
├── parsers/ndjson.ex               # NDJSON stream parser (Ollama)
├── request.ex                      # Request orchestration (build, stream, validate, parse_event)
├── loop.ex                         # Recursive stream loop (tool auto-execution)
├── agent.ex                        # Agent behaviour, use macro, public API
├── agent/{state,server,step,executor}.ex  # Agent internals
├── provider.ex                     # Provider behaviour + shared utilities
├── providers/{anthropic,openai,ollama,...}.ex
├── dialect.ex                      # Dialect behaviour
└── dialects/{anthropic_messages,openai_completions,openai_responses,ollama_chat,...}.ex
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks are separate structs under `Omni.Content` — pattern match on struct name, not a type field.
- Providers use `use Omni.Provider, dialect: Module` — the macro generates `dialect/0` and defaults for all optional callbacks. Provider IDs are assigned in the application config, not on the module. Built-in providers are registered in `@builtin_providers` (a static `%{id => module}` map in `Omni.Provider`). Not all built-in providers are loaded by default — `@default_providers` in `Omni.Application` controls what loads at startup (OpenRouter and Ollama are opt-in). Users override via `config :omni, :providers, [:anthropic, :openai, custom: MyApp.Custom]`. Shorthand atoms are looked up in the built-in map; custom providers use `{id, Module}` tuples. `Provider.load/1` loads providers into `:persistent_term` on demand and merges with existing entries, so it can be called multiple times safely. Models are stored in `:persistent_term` keyed as `{Omni, provider_id}`.
- Provider `config/0` returns `%{base_url, auth_header, api_key, headers}`. The `api_key` value is a `resolve_auth/1` term — typically `{:system, "ENV_VAR"}`. The `auth_header` defaults to `"authorization"` when omitted.
- API key resolution order (three-tier): explicit `:api_key` opt at call site → `config :omni, ProviderModule, api_key: ...` app config → provider's `config()` default. All three accept the same value types: literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}` MFA tuple.
- Tool modules use `use Omni.Tool, name: "string", description: "string"` — generates `new/0,1` constructors. Import `Omni.Schema` inside the `schema/0` callback (not at module level, not auto-imported by `use Omni.Tool`).
- The term is "tool use", not "tool call" (aligns with Anthropic's API, used consistently throughout).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- `Message.private` is a `%{}` map for provider-specific opaque round-trip data (named after Req's `private` convention). Dialects/providers write to it during parsing, read during encoding. Users pass it through untouched. Flat atom keys, no namespacing.
- Content blocks may carry a `signature` field (cross-provider concept for round-trip integrity tokens). `Thinking.redacted_data` holds Anthropic's encrypted redacted thinking blob — when present, `text` is `nil` and nothing should be rendered. Provider-specific data that doesn't change block semantics goes in `Message.private`, not on content blocks.
- Struct constructors (`new/1`) return bare structs and do not validate field values. Validation happens once at the API boundary (Peri schemas in the top-level `generate_text`/`stream_text` path). Constructors may normalize for convenience (e.g. string → `[%Text{}]`) but not reject bad data.
- `Omni.Schema` builder functions preserve property keys as-is — atom keys stay atoms, string keys stay strings. Do not stringify keys; JSON serialisation handles that on the wire. Snake_case option keywords are normalized to camelCase JSON Schema keywords (e.g. `min_length:` → `minLength`). `Omni.Schema.validate/2` converts schemas to Peri internally for validation.
- `Tool.execute/2` validates and casts input via Peri before calling the handler. Peri maps string-keyed LLM input back to the key types in the schema, so handlers use `input.city` (atom access) when the schema uses atom keys. Direct handler calls bypass validation/casting.
- Supported modalities are defined on `Omni.Model` (source of truth). Input: `:text`, `:image`, `:pdf`. Output: `:text`. The `Model.new/1` constructor filters modalities to the supported set (normalization). The mix task also filters and rejects models that lack text input.
- Structured output (`:output` option) wire format is dialect-specific: Anthropic uses `output_config.format` with `json_schema` and adds `additionalProperties: false` for object schemas; OpenAI Completions uses `response_format` with `strict: true`; OpenAI Responses uses `text.format` with `strict: true`; Google Gemini uses `generationConfig.responseMimeType` + `responseSchema` (no `additionalProperties` — Google doesn't support it); Ollama uses `format` with the JSON schema directly (no wrapper). Each dialect applies its own strictness mechanism rather than a shared pre-processing step.
- `doc/` is ExDoc output (gitignored). `context/` contains detailed design documents (see [Context Documents](#context-documents)).

## Testing

Tests are organized in four layers, none of which require API keys except live tests:

1. **Unit tests** (`test/omni/`) — pure logic, no HTTP. SSE and NDJSON parser tests pass plain lists of binary chunks. Provider tests inspect `%Req.Request{}` structs without executing them. Dialect tests verify `handle_event/1` and `handle_body/3` in isolation.
2. **Integration tests** (`test/integration/`) — use `Req.Test.stub/2` with a plug to simulate HTTP responses. One file per provider (anthropic, openai, google, openrouter, ollama) plus `error_test.exs` for cross-cutting error/edge cases. All tests go through the top-level `Omni.generate_text/3` and `Omni.stream_text/3` API. Use `Omni.get_model/2` for model resolution. Assertions are loose/structural (no specific strings or token counts) since fixtures are real API recordings that may be regenerated.
3. **Live tests** (`test/live/`) — tagged `@moduletag :live`, excluded by default. Run with `mix test --include live`. One file per provider with text, tool use, and thinking tests. Require API keys via environment variables (e.g. `ANTHROPIC_API_KEY`). Ollama live tests require a local Ollama instance. Use `direnv` with a `.envrc` file (gitignored).
4. **Capture helper** — `Omni.Test.Capture.record/5` in `test/support/capture.ex` records real API responses as fixture files.

**Fixtures:** SSE fixtures (`test/support/fixtures/sse/`) and NDJSON fixtures (`test/support/fixtures/ndjson/`) are real API recordings, committed so CI never needs API keys. Synthetic fixtures (`test/support/fixtures/synthetic/`) are hand-crafted SSE data for controlled error/edge case scenarios — tests can assert exact values.

`test/support/` is compiled in the test environment via `elixirc_paths`.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless the type is complex enough to warrant further explanation.
- All public functions must have a `@doc`. One sentence is fine if the function is self-explanatory; add more detail for complex behaviour. Rely on `@spec` for types — don't repeat type info in prose.
- Document options when a function accepts them (keyword lists, maps with known keys).
- Only add examples for important top-level API functions or where behaviour is non-obvious.
- Private functions (`defp`) do not need `@doc` annotations.
- Tone: practical over theoretical, concise, example-driven for key APIs. Lead with what you do, not what things are. No hedging ("Returns a response" not "This function is used to return a response").

## Context Documents

The `context/` directory contains detailed design documents. This CLAUDE.md provides sufficient context for most tasks — consult the design docs when working in depth on a specific subsystem.

- **`context/design.md`** — Full architecture reference covering: top-level API, models and data loading, providers (behaviour, callbacks, config, auth), dialects (behaviour, callbacks, option validation), messages and content blocks, streaming pipeline (SSE/NDJSON, deltas, StreamingResponse), tools (struct, schema, modules, execution), and request flow.
- **`context/agent.md`** — Agent system: GenServer architecture, public API, lifecycle callbacks (`init`, `handle_tool_call`, `handle_tool_result`, `handle_stop`, `handle_error`, `terminate`), process model (Step/Executor/Tool Tasks), pause/resume, prompt queuing/steering, context management, and the completion tool pattern.
- **`context/roadmap.md`** — Pre-v1 checklist and future work.
- **`context/provider-apis.md`** — Provider API documentation URLs (fetch on demand when working on a specific provider/dialect).
