# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. It separates three concerns:

- **Models** — data structs describing a specific LLM (loaded from JSON in `priv/models/`)
- **Providers** — authenticated HTTP layer (where to send requests, how to authenticate)
- **Dialects** — wire format translation (how to build request bodies, parse streaming events)

The relationship: ~4-5 dialects, ~20-30 providers (each speaking one dialect), hundreds of models (each belonging to one provider). All requests are streaming-first; `generate_text` is built on top of `stream_text`.

See `context/design.md` for the full design document and `context/roadmap.md` for the phased implementation plan.

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

- **Streaming-first**: Every LLM request uses streaming HTTP via Req's `into: :self` async mode. The event pipeline is composed as a lazy `Stream`: SSE parsing → `Provider.parse_event/2` (adapt + dialect parse) → delta tuples. `parse_event` returns a list of `{type, map}` tuples (4 generic types: `:message`, `:block_start`, `:block_delta`, `:error`), so the pipeline uses `Stream.flat_map/2`. `StreamingResponse.new/2` takes raw delta events and keyword opts (`model`, `cancel`, `raw`), building the full consumer event pipeline at construction time via `Stream.transform/5`. The struct holds two fields: `stream` (the pipeline) and `cancel` (an opaque zero-arity function). Model and raw HTTP data are baked into the transform closure, not stored on the struct. Its `Enumerable` implementation delegates directly to the pipeline, yielding `{event_type, event_map, partial_response}` tuples. Key functions: `text_stream/1` (stream of text delta binaries), `complete/1` (consume to final `%Response{}`), `cancel/1` (invoke cancel function). `Stream.transform/5`'s `last_fun` handles finalization — `:done` is only emitted on success, not after `:error`. No spawned process — Req/Finch manage the connection.

- **Models are data, not modules**: `%Model{}` structs are loaded from `priv/models/*.json` at startup into `:persistent_term` (keyed per provider). Models carry a direct module reference to their provider; the dialect is accessed via `provider.dialect()`.

- **Request building separated from execution**: `Provider.build_request/3` takes Omni types (model, context, opts) and returns a `%Req.Request{}` via dialect + provider composition. `Provider.new_request/4` takes raw provider params (path, body, opts) and returns a `%Req.Request{}`. Both build without executing — the caller runs `Req.request/1`. The dialect does heavy transformation (Omni types ↔ native JSON). The provider optionally adapts dialect output for service-specific quirks via `adapt_body/2` and `adapt_event/1`.

- **Two message roles only**: `:user` and `:assistant`. No `:tool` role — tool results are `Content.ToolResult` blocks inside user messages. Role differences are expressed through content blocks, not message types.

- **Single validation pass**: Options from dialect, provider, and base request schemas are merged into one Peri schema and validated once before any work begins.

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
├── schema.ex                       # JSON Schema builder functions
├── content/{text,thinking,attachment,tool_use,tool_result}.ex
├── sse.ex                          # Shared SSE parser
├── provider.ex                     # Provider behaviour + shared HTTP logic
├── providers/{anthropic,openai,...}.ex
├── dialect.ex                      # Dialect behaviour
└── dialects/{anthropic_messages,openai_completions,openai_responses,...}.ex
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks are separate structs under `Omni.Content` — pattern match on struct name, not a type field.
- Providers use `use Omni.Provider, dialect: Module` — the macro generates `dialect/0` and defaults for all optional callbacks. Provider IDs are assigned in the application config, not on the module. Built-in providers are registered in `@builtin_providers` (a static `%{id => module}` map in `Omni.Provider`). Not all built-in providers are loaded by default — `@default_providers` in `Omni.Application` controls what loads at startup (OpenRouter is opt-in). Users override via `config :omni, :providers, [:anthropic, :openai, custom: MyApp.Custom]`. Shorthand atoms are looked up in the built-in map; custom providers use `{id, Module}` tuples. `Provider.load/1` loads providers into `:persistent_term` on demand and merges with existing entries, so it can be called multiple times safely. Models are stored in `:persistent_term` keyed as `{Omni, provider_id}`.
- Provider `config/0` returns `%{base_url, auth_header, api_key, headers}`. The `api_key` value is a `resolve_auth/1` term — typically `{:system, "ENV_VAR"}`. The `auth_header` defaults to `"authorization"` when omitted.
- API key resolution order (three-tier): explicit `:api_key` opt at call site → `config :omni, ProviderModule, api_key: ...` app config → provider's `config()` default. All three accept the same value types: literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}` MFA tuple.
- Tool modules use `use Omni.Tool, name: "string", description: "string"` — generates `new/0,1` constructors. Import `Omni.Schema` inside the `schema/0` callback (not at module level, not auto-imported by `use Omni.Tool`).
- The term is "tool use", not "tool call" (aligns with Anthropic's API, used consistently throughout).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- `Message.private` is a `%{}` map for provider-specific opaque round-trip data (named after Req's `private` convention). Dialects/providers write to it during parsing, read during encoding. Users pass it through untouched. Flat atom keys, no namespacing.
- Content blocks may carry a `signature` field (cross-provider concept for round-trip integrity tokens). `Thinking.redacted_data` holds Anthropic's encrypted redacted thinking blob — when present, `text` is `nil` and nothing should be rendered. Provider-specific data that doesn't change block semantics goes in `Message.private`, not on content blocks.
- Struct constructors (`new/1`) return bare structs and do not validate field values. Validation happens once at the API boundary (Peri schemas in the top-level `generate_text`/`stream_text` path). Constructors may normalize for convenience (e.g. string → `[%Text{}]`) but not reject bad data.
- `Omni.Schema` builder functions preserve keys as-is — atom keys stay atoms, string keys stay strings. Do not stringify keys; JSON serialisation handles that on the wire. `Omni.Schema.to_peri/1` converts schemas to Peri for validation.
- `Tool.execute/2` validates and casts input via Peri before calling the handler. Peri maps string-keyed LLM input back to the key types in the schema, so handlers use `input.city` (atom access) when the schema uses atom keys. Direct handler calls bypass validation/casting.
- Supported modalities are defined on `Omni.Model` (source of truth). Input: `:text`, `:image`, `:pdf`. Output: `:text`. The `Model.new/1` constructor filters modalities to the supported set (normalization). The mix task also filters and rejects models that lack text input.
- `doc/` is ExDoc output (gitignored). `context/` contains project design documents for LLM context.

## Testing

Tests are organized in four layers, none of which require API keys except live tests:

1. **Unit tests** — pure logic, no HTTP. SSE parser tests pass plain lists of binary chunks. Provider tests inspect `%Req.Request{}` structs without executing them.
2. **Mocked integration tests** — use `Req.Test.stub/2` with a plug to simulate HTTP responses. The plug returns SSE fixture data; `Req.merge(req, plug: {Req.Test, :name})` injects it into a request built by `new_request/4`. This exercises the full path: request building → Req execution → SSE parsing.
3. **Live tests** — tagged `@moduletag :live`, excluded by default. Run with `mix test --include live`. Require API keys via environment variables (e.g. `ANTHROPIC_API_KEY`). Use `direnv` with a `.envrc` file (gitignored).
4. **Capture helper** — `Omni.Test.Capture.record/5` in `test/support/capture.ex` records real API responses as SSE fixture files. The `.sse` files in `test/support/fixtures/sse/` are committed so CI never needs API keys.

`test/support/` is compiled in the test environment via `elixirc_paths`.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless the type is complex enough to warrant further explanation.
- All public functions must have a `@doc`. One sentence is fine if the function is self-explanatory; add more detail for complex behaviour. Rely on `@spec` for types — don't repeat type info in prose.
- Document options when a function accepts them (keyword lists, maps with known keys).
- Only add examples for important top-level API functions or where behaviour is non-obvious.
- Private functions (`defp`) do not need `@doc` annotations.
