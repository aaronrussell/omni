# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. It separates three concerns:

- **Models** — data structs describing a specific LLM (loaded from a pluggable model source; the default reads the bundled models.dev snapshot in `priv/models/`)
- **Providers** — data structs for the authenticated HTTP layer (where to send requests, how to authenticate), assembled from catalog data, an optional provider module, and config
- **Dialects** — wire format translation (how to build request bodies, parse streaming events)

The relationship: ~4-5 dialects, hundreds of possible providers (13 verified built-ins; any models.dev catalog provider loads by id; most speak one dialect, though multi-model gateways like OpenCode Zen use several), thousands of models (each belonging to one provider). Each `%Model{}` embeds its `%Provider{}` and names its dialect per capability, so dispatch is always per-model. All requests are streaming-first; `generate_text` is built on top of `stream_text`.

The agent system (`Omni.Agent`) lives in a separate package — [`omni_agent`](https://github.com/aaronrussell/omni_agent). This package is purely the stateless LLM API layer.

See the [Context Documents](#context-documents) section for when and how to use the detailed design docs.

## Build & Development Commands

```bash
mix precommit                 # Compile (warnings as errors), unlock unused deps, format, test
mix compile                   # Compile the project
mix test                      # Run all tests
mix test --include live       # Run all tests including live API tests (needs API keys)
mix test path/to/test.exs     # Run a single test file
mix test path/to/test.exs:42  # Run a specific test (line number)
mix format                    # Format all code
mix format --check-formatted  # Check formatting without changing files
mix omni.snapshot             # Capture a models.dev snapshot into priv/models/
```

Run `mix precommit` before considering any change done. It fixes formatting and prunes unused lock entries in place; CI runs the non-mutating equivalents (`format --check-formatted`, `deps.unlock --check-unused`) and fails on any warning. Don't run it with `OMNI_SKIP_LLMDB` set — the unlock step would drop `llm_db` from `mix.lock`.

`mix omni.snapshot` writes the full [models.dev](https://models.dev) catalog to `priv/models/models_dev.json` (checked into the repo) — content verbatim, encoding normalized (pretty-printed, sorted keys) for diffable git history. `Omni.Sources.ModelsDev` transforms the snapshot at load time — filtering out deprecated models and those without tool use support, and inferring each model's `dialect` from models.dev's npm package metadata. A live mode (`source: {Omni.Sources.ModelsDev, live: true}`) fetches fresh catalog data from models.dev at boot with a tmp-dir disk cache, degrading to stale cache and then the bundled snapshot when unreachable. Run the task manually when model data needs refreshing, and update the golden test expectations (`test/omni/sources/models_dev_golden_test.exs`) alongside.

## Dependencies

- **Req** (`~> 0.5`) — HTTP client (used for streaming requests to LLM APIs)
- **Peri** (`~> 0.6`) — Schema-based validation (used for option validation)
- **ExDoc** (dev only) — Documentation generation
- **Plug** (test only) — Required for `Req.Test` plug-based mocking

## Architecture

### Key design patterns

- **Streaming-first**: Every LLM request uses streaming HTTP via Req's `into: :self` async mode. The event pipeline is a lazy `Stream`: format parsing (SSE or NDJSON) → `Request.parse_event/2` (dialect `handle_event/2`, which receives the model) → delta tuples. `StreamingResponse.new/2` builds the consumer pipeline via `Stream.transform/5`. The struct holds `stream` (the pipeline) and `cancel` (a zero-arity function). `Enumerable` yields `{event_type, data, partial_response}` tuples. Key functions: `on/3` (pipeline-composable side-effect handler), `text_stream/1`, `complete/1`, `cancel/1`. `:done` is only emitted when a stop reason was received; incomplete streams emit `{:error, :incomplete_stream}`.

- **Models and providers are data, not modules**: `%Provider{}` structs and their `%Model{}` structs are assembled by `Omni.Provider.Loader` at startup and stored in `:persistent_term`. Layers, later winning: source catalog data (`Omni.Source.fetch/2`) ← provider module `config/0` ← `config :omni, :providers, <id>: [...]`. Each model embeds its provider and carries `dialects: %{text: Module}`; the provider's `dialects: %{text: [Module, ...]}` list is derived from its models. Model data decides a model's dialect — configured `dialects:` only fills models with none. Nothing is looked up at request time.

- **Request building separated from execution**: `Request.build/3` validates options via Peri and returns a `%Req.Request{}` via dialect + provider composition. `Request.stream/3` executes and returns a `StreamingResponse`. The dialect transforms Omni types ↔ native JSON. Auth is data on the provider (`:bearer`, `{:header, name}`, `:none`, or `:dialect` — the dialect's home scheme via `Dialect.auth/0`). Provider quirks are compat flags (`provider.compat`, keyed by dialect module) that the dialect reads at encode time, validated against each dialect's `compat_schema/0` at load. An optional provider module covers what flags can't, via `modify_body/4` and `modify_request/3`.

- **Two message roles only**: `:user` and `:assistant`. No `:tool` role — tool results are `Content.ToolResult` blocks inside user messages.

- **Recursive stream loop**: `Omni.Loop` handles tool auto-execution and structured output validation via recursive `Stream.flat_map`. `stream_text/3` always delegates to `Loop.stream/3`. Tools execute in parallel via `Tool.Runner.run/3`. `:max_steps` (default `:infinity`) caps rounds. When `:output` is set, the loop validates against the schema and retries up to 3 times on failure.

- **Single validation pass**: `Request.validate/2` merges universal + dialect option schemas, merges the provider's `base_url`/`api_key`/`headers` (which already absorbed app config) with call-site opts, and validates via Peri in one pass.

### Module layout

```
lib/omni.ex                         # Top-level API: generate_text, stream_text, get_model
lib/omni/
├── application.ex                  # Boots Omni.Provider.Loader at startup
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
├── provider.ex                     # Provider struct + module behaviour + get/load/resolve_auth
├── provider/builtins.ex            # Built-in provider ids → modules
├── provider/loader.ex              # Assembly, merging, validation, store, boot config checks
├── providers/{anthropic,openai,ollama,opencode,...}.ex   # Built-in provider modules
├── source.ex                       # Source behaviour + build_model/1 + memo cache
├── sources/{models_dev,llmdb}.ex
├── dialect.ex                      # Dialect behaviour + string→module registry
└── dialects/{anthropic_messages,openai_completions,openai_responses,ollama_chat,...}.ex
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks are separate structs under `Omni.Content` — pattern match on struct name, not a type field.
- A provider's id is its models.dev catalog key snake_cased as an atom (e.g. `:moonshotai`, `:ollama_cloud`). The id is the single identity: config keys, `get_model/2` lookup, and source catalog lookup all use it (sources translate to their native key format themselves). There is no renaming; an id the catalog doesn't know is a custom provider defined in config.
- `config :omni, :models` selects: `providers:` (ids, `:builtins` expanding to `Omni.Provider.Builtins`), `source:`, `filter:`. `config :omni, :providers` configures by id: `name`, `base_url` (includes the version segment — dialect paths are resource paths only), `api_key`, `auth`, `headers`, `dialects`, `compat`, `module`, `models`, `source`. Configuring never enables. Merge rule: values replace; `headers` merge by key, `dialects` by capability, `compat` by dialect then flag, `models` by id. `compat` is a flat keyword list (single-dialect providers; `like: :builtin_id` copies a built-in's flags) or a map keyed by dialect module. v1-style config raises at boot with a migration message.
- Provider modules declare `@behaviour Omni.Provider`; every callback is optional (`config/0`, `models/2`, `modify_request/3`, `modify_body/4`). Modules carry no id — built-ins are mapped in `Omni.Provider.Builtins`, others are attached with `module:` in config. Built-in modules set their verified `base_url`, `api_key` and `compat` (keyed by dialect, so `like:` can copy it) explicitly in `config/0`.
- API key resolution: call-site `:api_key` opt → provider value (source, module, app config). Accepts literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}`.
- Store: `{Omni, :providers}` holds `%{id => %Provider{}}`; `{Omni, :models, id}` holds `%{model_id => %Model{}}`. Writes go through the Loader. Unknown or unloaded providers return `{:error, {:unknown_provider, id}}`.
- Tool modules use `use Omni.Tool, name: "string", description: "string"`. The `name:` and `description:` options are optional — omit them to implement `name/0` and `description/0` as callbacks directly. Override `description/1` to incorporate `init/1` state into the description. Import `Omni.Schema` inside the `schema/0` callback, not at module level.
- The term is "tool use", not "tool call" (aligns with Anthropic's API).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- `Message.private` is a `%{}` map for provider-specific opaque round-trip data. Dialects/providers write during parsing, read during encoding. Flat atom keys.
- Content blocks may carry a `signature` field (round-trip integrity tokens). `Thinking.redacted_data` holds Anthropic's encrypted redacted thinking — when present, `text` is `nil`. Provider-specific data goes in `Message.private`, not on content blocks.
- Struct constructors (`new/1`) return bare structs without validation. Validation happens once at the API boundary via Peri schemas.
- `Omni.Schema` preserves property key types as-is. Snake_case option keywords normalize to camelCase JSON Schema keywords.
- `Tool.execute/2` validates and casts input via Peri before calling the handler — string-keyed LLM input maps back to schema key types.
- `Model.thinking` is `false`, `true` (reasons, no detail), or `%{efforts, toggle, budget}` from catalog `reasoning_options`. Dialects translate the `:thinking` option through `Omni.Dialect.Thinking.resolve/2` (shared clamping and budgets); no dialect matches on model-name prefixes for thinking. `thinking: true` is dynamic thinking.
- Compat flags are named by wire shape or Omni concept, never by provider; absent means the dialect's home-API behaviour. A flag ships only with a verified provider that uses it.
- Supported modalities defined on `Omni.Model`. Input: `:text`, `:image`, `:pdf`. Output: `:text`.
- Structured output wire format is dialect-specific. Each dialect applies its own strictness mechanism.
- `%Response{}` carries `messages`, `usage`, and `stop_reason` (includes `:cancelled`). `:message` is optional.
- Filesystem path naming: `*_dir` for directories, `*_file` for files, `*_path` for generic or non-filesystem paths (e.g. URL paths). Applies to config keys, function params, variables, and module attributes.

## Testing

Tests are organized in four layers, none of which require API keys except live tests:

1. **Unit tests** (`test/omni/`) — pure logic, no HTTP. Parser, provider, and dialect tests in isolation. Build structs with `Omni.Test.Fixtures`; assemble providers with `Omni.Provider.Loader.assemble/2` (never writes the store) rather than loading them.
2. **Integration tests** (`test/integration/`) — use `Req.Test.stub/2` with a plug to simulate HTTP. One file per provider plus `error_test.exs`; `request_target_test.exs` asserts every built-in's host, path and auth headers. All go through the top-level API. Assertions are loose/structural since fixtures are real API recordings.
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
