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

## Architecture

### Key design patterns

- **Streaming-first**: Every LLM request uses streaming HTTP. The SSE parser, provider event adaptation, and dialect event parsing run in a spawned process. Deltas are sent as messages to the caller, where `StreamingResponse`'s `Enumerable` implementation accumulates a partial `%Response{}` and yields `{event_type, event_map, partial_response}` tuples.

- **Models are data, not modules**: `%Model{}` structs are loaded from `priv/models/*.json` at startup into `:persistent_term` (keyed per provider). Models carry direct module references to their provider and dialect, making them self-contained for callback dispatch.

- **Provider builds URL + authenticates; dialect builds body + parses events**: The dialect does heavy transformation (Omni types ↔ native JSON). The provider optionally adapts dialect output for service-specific quirks via `adapt_body/2` and `adapt_event/1`.

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
├── dialects/{anthropic_messages,openai_completions,...}.ex
└── auth.ex                         # API key resolution (literal, {:system, env}, MFA)
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks are separate structs under `Omni.Content` — pattern match on struct name, not a type field.
- Providers use `use Omni.Provider, dialect: Module` — the macro generates `dialect/0`. Provider IDs are assigned in the application config, not on the module.
- Tool modules use `use Omni.Tool, name: "string", description: "string"` — generates `new/0,1` constructors. Import `Omni.Schema` inside the `schema/0` callback (not at module level, not auto-imported by `use Omni.Tool`).
- The term is "tool use", not "tool call" (aligns with Anthropic's API, used consistently throughout).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- Struct constructors (`new/1`) return bare structs and do not validate field values. Validation happens once at the API boundary (Peri schemas in the top-level `generate_text`/`stream_text` path). Constructors may normalize for convenience (e.g. string → `[%Text{}]`) but not reject bad data.
- `Omni.Schema` builder functions preserve keys as-is — atom keys stay atoms, string keys stay strings. Do not stringify keys; JSON serialisation handles that on the wire. `Omni.Schema.to_peri/1` converts schemas to Peri for validation.
- `Tool.execute/2` validates and casts input via Peri before calling the handler. Peri maps string-keyed LLM input back to the key types in the schema, so handlers use `input.city` (atom access) when the schema uses atom keys. Direct handler calls bypass validation/casting.
- `doc/` is ExDoc output (gitignored). `context/` contains project design documents for LLM context.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless the type is complex enough to warrant further explanation.
- All public functions must have a `@doc`. One sentence is fine if the function is self-explanatory; add more detail for complex behaviour. Rely on `@spec` for types — don't repeat type info in prose.
- Document options when a function accepts them (keyword lists, maps with known keys).
- Only add examples for important top-level API functions or where behaviour is non-obvious.
- Private functions (`defp`) do not need `@doc` annotations.
