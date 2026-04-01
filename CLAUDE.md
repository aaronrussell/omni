# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. It separates three concerns:

- **Models** — data structs describing a specific LLM (loaded from JSON in `priv/models/`)
- **Providers** — authenticated HTTP layer (where to send requests, how to authenticate)
- **Dialects** — wire format translation (how to build request bodies, parse streaming events)

The relationship: ~4-5 dialects, ~20-30 providers (most speaking one dialect, though multi-model gateways like OpenCode Zen use multiple), hundreds of models (each belonging to one provider). The dialect is stored on each `%Model{}` struct, so dispatch is always per-model. All requests are streaming-first; `generate_text` is built on top of `stream_text`.

The agent system (`Omni.Agent`) lives in a separate package — [`omni_agent`](https://github.com/aaronrussell/omni_agent). This package is purely the stateless LLM API layer.

See the [Context Documents](#context-documents) section for when and how to use the detailed design docs.

## Build & Development Commands

```bash
mix compile                   # Compile the project
mix test                      # Run all tests
mix test --include live       # Run all tests including live API tests (needs API keys)
mix test path/to/test.exs     # Run a single test file
mix test path/to/test.exs:42  # Run a specific test (line number)
mix format                    # Format all code
mix format --check-formatted  # Check formatting without changing files
mix models.get                # Fetch model data from models.dev into priv/models/
```

`mix models.get` fetches model catalogs from [models.dev](https://models.dev) for each provider listed in its `@providers` attribute. It filters out deprecated models and those without tool use support. The JSON files in `priv/models/` are checked into the repo — run this task manually when model data needs refreshing.

## Dependencies

- **Req** (`~> 0.5`) — HTTP client (used for streaming requests to LLM APIs)
- **Peri** (`~> 0.6`) — Schema-based validation (used for option validation)
- **ExDoc** (dev only) — Documentation generation
- **Plug** (test only) — Required for `Req.Test` plug-based mocking

## Architecture

### Key design patterns

- **Streaming-first**: Every LLM request uses streaming HTTP via Req's `into: :self` async mode. The event pipeline is a lazy `Stream`: format parsing (SSE or NDJSON) → `Request.parse_event/2` (dialect `handle_event/1` + provider `modify_events/2`) → delta tuples. `StreamingResponse.new/2` builds the consumer pipeline via `Stream.transform/5`. The struct holds `stream` (the pipeline) and `cancel` (a zero-arity function). `Enumerable` yields `{event_type, data, partial_response}` tuples. Key functions: `on/3` (pipeline-composable side-effect handler), `text_stream/1`, `complete/1`, `cancel/1`. `:done` is only emitted when a stop reason was received; incomplete streams emit `{:error, :incomplete_stream}`.

- **Models are data, not modules**: `%Model{}` structs are loaded from `priv/models/*.json` at startup into `:persistent_term`. Models carry direct module references to their provider and dialect — the dialect is on the model, not derived from the provider, enabling multi-dialect providers.

- **Request building separated from execution**: `Request.build/3` validates options via Peri and returns a `%Req.Request{}` via dialect + provider composition. `Request.stream/3` executes and returns a `StreamingResponse`. The dialect transforms Omni types ↔ native JSON. The provider optionally modifies via `modify_body/3` and `modify_events/2`.

- **Two message roles only**: `:user` and `:assistant`. No `:tool` role — tool results are `Content.ToolResult` blocks inside user messages.

- **Recursive stream loop**: `Omni.Loop` handles tool auto-execution and structured output validation via recursive `Stream.flat_map`. `stream_text/3` always delegates to `Loop.stream/3`. Tools execute in parallel via `Tool.Runner.run/3`. `:max_steps` (default `:infinity`) caps rounds. When `:output` is set, the loop validates against the schema and retries up to 3 times on failure.

- **Single validation pass**: `Request.validate/2` merges universal + dialect option schemas, does a three-tier config merge (provider config ← app config ← call-site opts), and validates via Peri in one pass.

### Module layout

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
├── util.ex                         # Shared helpers (maybe_put, maybe_merge)
├── content/{text,thinking,attachment,tool_use,tool_result}.ex
├── parsers/sse.ex                  # SSE stream parser
├── parsers/ndjson.ex               # NDJSON stream parser (Ollama)
├── request.ex                      # Request orchestration (build, stream, validate, parse_event)
├── loop.ex                         # Recursive stream loop (tool auto-execution)
├── provider.ex                     # Provider behaviour + shared utilities + dialect registry
├── providers/{anthropic,openai,ollama,open_code,...}.ex
├── dialect.ex                      # Dialect behaviour + string→module registry
└── dialects/{anthropic_messages,openai_completions,openai_responses,ollama_chat,...}.ex
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks are separate structs under `Omni.Content` — pattern match on struct name, not a type field.
- Providers use `use Omni.Provider` with an optional `:dialect` option. Single-dialect providers pass `dialect: Module`. Multi-dialect providers omit it — each model gets its dialect from the JSON data file via `Omni.Dialect.get!/1`. Provider IDs are assigned in application config, not on the module. Built-in providers are in `@builtin_providers` on `Omni.Provider`; `@default_providers` in `Omni.Application` controls startup loading. Users override via `config :omni, :providers`. Models are stored in `:persistent_term` keyed as `{Omni, provider_id}`.
- Provider `config/0` returns `%{base_url, auth_header, api_key, headers}`. API key resolution: call-site `:api_key` opt → app config → provider default. Accepts literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}`.
- Tool modules use `use Omni.Tool, name: "string", description: "string"`. The `name:` and `description:` options are optional — omit them to implement `name/0` and `description/0` as callbacks directly. Override `description/1` to incorporate `init/1` state into the description. Import `Omni.Schema` inside the `schema/0` callback, not at module level.
- The term is "tool use", not "tool call" (aligns with Anthropic's API).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- `Message.private` is a `%{}` map for provider-specific opaque round-trip data. Dialects/providers write during parsing, read during encoding. Flat atom keys.
- Content blocks may carry a `signature` field (round-trip integrity tokens). `Thinking.redacted_data` holds Anthropic's encrypted redacted thinking — when present, `text` is `nil`. Provider-specific data goes in `Message.private`, not on content blocks.
- Struct constructors (`new/1`) return bare structs without validation. Validation happens once at the API boundary via Peri schemas.
- `Omni.Schema` preserves property key types as-is. Snake_case option keywords normalize to camelCase JSON Schema keywords.
- `Tool.execute/2` validates and casts input via Peri before calling the handler — string-keyed LLM input maps back to schema key types.
- Supported modalities defined on `Omni.Model`. Input: `:text`, `:image`, `:pdf`. Output: `:text`.
- Structured output wire format is dialect-specific. Each dialect applies its own strictness mechanism.
- `%Response{}` carries `messages`, `usage`, and `stop_reason` (includes `:cancelled`). `:message` is optional.

## Testing

Tests are organized in four layers, none of which require API keys except live tests:

1. **Unit tests** (`test/omni/`) — pure logic, no HTTP. Parser, provider, and dialect tests in isolation.
2. **Integration tests** (`test/integration/`) — use `Req.Test.stub/2` with a plug to simulate HTTP. One file per provider plus `error_test.exs`. All go through the top-level API. Assertions are loose/structural since fixtures are real API recordings.
3. **Live tests** (`test/live/`) — tagged `@moduletag :live`, excluded by default. Run with `mix test --include live`. Require API keys via environment variables.
4. **Capture helper** — `Omni.Test.Capture.record/5` records real API responses as fixture files.

**Fixtures:** SSE and NDJSON fixtures are real API recordings in `test/support/fixtures/`. Synthetic fixtures are hand-crafted for controlled error/edge case scenarios.

`test/support/` is compiled in the test environment via `elixirc_paths`.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless complex.
- All public functions must have a `@doc`. Rely on `@spec` for types — don't repeat in prose.
- Document options when a function accepts them.
- Private functions (`defp`) do not need `@doc` annotations.
- Tone: practical, concise, example-driven. Lead with what you do, not what things are.

## Context Documents

The `context/` directory contains detailed design documents. This CLAUDE.md provides sufficient context for most tasks — consult the design docs when working in depth on a specific subsystem.

- **`context/design.md`** — Full architecture reference: top-level API, models, providers, dialects, messages and content blocks, streaming pipeline, tools, and request flow.
- **`context/roadmap.md`** — Future work.
- **`context/provider-apis.md`** — Provider API documentation URLs (fetch on demand when working on a specific provider/dialect).
