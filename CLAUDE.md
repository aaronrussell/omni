# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. It separates three concerns:

- **Models** — data structs describing a specific LLM (loaded from a pluggable model source; the default reads the bundled models.dev snapshot in `priv/models/`)
- **Providers** — data structs for the authenticated HTTP layer (an endpoint per dialect they serve, with its URL and compat flags; how to authenticate), assembled from catalog data, an optional provider module, and config
- **Dialects** — wire format translation (how to build request bodies, parse streaming events or JSON responses)

Two capabilities (kinds of request): **text** generation (`generate_text/3`, `stream_text/3`) and **decisions** (`decide/3`: typed questions over a shared state, answered with probabilities). The relationship: seven dialects (five text, two decision), hundreds of possible providers (17 built-ins; any models.dev catalog provider loads by id; most speak one dialect, though multi-model gateways like OpenCode Zen use several), thousands of models (each belonging to one provider). Each `%Model{}` embeds its `%Provider{}` and names its dialect per capability, so dispatch is always per-model. Text is streaming-first (`generate_text` is built on top of `stream_text`); a decision is one JSON request and response.

The agent system (`Omni.Agent`) lives in a separate package — [`omni_agent`](https://github.com/aaronrussell/omni_agent). This package is purely the stateless LLM API layer.

See the [Context Documents](#context-documents) section for when and how to use the detailed design docs.

## Build & Development Commands

```bash
mix precommit                 # Compile (warnings as errors), unlock unused deps, format, test
mix compile                   # Compile the project
mix test                      # Run all tests
mix test path/to/test.exs     # Run a single test file
mix test path/to/test.exs:42  # Run a specific test (line number)
mix format                    # Format all code
mix format --check-formatted  # Check formatting without changing files
mix omni.snapshot             # Capture a models.dev snapshot into priv/models/
mix omni.verify <provider> <model>   # Run live scenarios against one model (real, billed requests)
mix run scripts/verify/sweep.exs [provider[/model] ...] [--only a,b] [--delay ms]  # Verify the model matrix; daily results in scripts/verify/results/
MIX_ENV=test mix run test/support/fixtures/<dir>/capture.exs   # Record missing fixtures (real, billed requests)
```

**Live API commands are run by the maintainer, never by an agent:** `mix omni.verify`, the sweep script and capture scripts make real, billed requests. Don't run them unless explicitly asked, and then only that once; hand over the command to run instead.

Run `mix precommit` before considering any change done. It fixes formatting and prunes unused lock entries in place; CI runs the non-mutating equivalents (`format --check-formatted`, `deps.unlock --check-unused`) and fails on any warning. Don't run it with `OMNI_SKIP_LLMDB` set — the unlock step would drop `llm_db` from `mix.lock`.

`mix omni.snapshot` writes the [models.dev](https://models.dev) catalog's chat and decision models (`api.json?type=chat,decision`) to `priv/models/models_dev.json` (checked into the repo) — content verbatim, encoding normalized (pretty-printed, sorted keys) for diffable git history. `Omni.Sources.ModelsDev` transforms the snapshot at load time — loading each model for one capability by its catalog `type` (untyped or `chat` → text, which must support tool use; `decision` → decision), filtering out deprecated models and every other type, and inferring each model's dialect from models.dev's npm package metadata (a separate table for decision models). A live mode (`source: {Omni.Sources.ModelsDev, live: true}`) fetches fresh catalog data from models.dev at boot with a tmp-dir disk cache, degrading to stale cache and then the bundled snapshot when unreachable. Run the task manually when model data needs refreshing, and update the golden test expectations (`test/omni/sources/models_dev_golden_test.exs`) alongside.

## Dependencies

- **Req** (`~> 0.5`) — HTTP client (used for streaming requests to LLM APIs)
- **Peri** (`~> 0.6`) — Schema-based validation (used for option validation)
- **ExDoc** (dev only) — Documentation generation
- **Plug** (test only) — Required for `Req.Test` plug-based mocking

## Architecture

### Key design patterns

- **Streaming-first text**: Every text request uses streaming HTTP via Req's `into: :self` async mode. The event pipeline is a lazy `Stream`: format parsing (SSE or NDJSON) → `Request.parse_event/2` (dialect `handle_event/2`, which receives the model) → delta tuples. `StreamingResponse.new/2` builds the consumer pipeline via `Stream.transform/5`. The struct holds `stream` (the pipeline) and `cancel` (a zero-arity function). `Enumerable` yields `{event_type, data, partial_response}` tuples. Key functions: `on/3` (pipeline-composable side-effect handler), `text_stream/1`, `complete/1`, `cancel/1`. `:done` is only emitted when a stop reason was received; incomplete streams emit `{:error, :incomplete_stream}`.

- **Models and providers are data, not modules**: `%Provider{}` structs and their `%Model{}` structs are assembled by `Omni.Provider.Loader` at startup and stored in `:persistent_term`. Layers, later winning: source catalog data (`Omni.Source.fetch/2`) ← provider module `config/0` ← `config :omni, :providers, <id>: [...]`. Each model embeds its provider and carries `dialects: %{text: Module, decision: Module}` (one or both); the provider's `dialects: %{Module => %Omni.Provider.Endpoint{base_url, compat}}` holds an endpoint per dialect it serves. A model's dialect comes from its catalog data or the module's `models/2` — never filled in: a catalog model without one (or without an endpoint for it) is skipped with a warning, a config model raises. Nothing is looked up at request time.

- **Request building separated from execution**: `Request.build/3` takes a `%Context{}` or `%Decision{}` (the struct picks the capability, hence dialect and endpoint), validates options via Peri and returns a `%Req.Request{}` via dialect + provider composition. `Request.stream/3` executes a text request and returns a `StreamingResponse`; `Request.send/4` executes a decision, hands the JSON body to the dialect's `handle_response/3` and prices usage with `Usage.price/2`. The dialect transforms Omni types ↔ native JSON. Auth is data on the provider (`:bearer`, `{:header, name}`, `:none`, or `:dialect` — the dialect's home scheme via `Dialect.auth/0`). The URL is one join: `endpoint.base_url` (origin swapped by a call-site `host:`) `<> dialect.handle_path/2`; a missing endpoint or URL is a request-time error (`{:no_endpoint, d}`, `{:no_base_url, d}`). Provider quirks are compat flags on each endpoint that the dialect reads at encode time (`Dialect.compat/2`), validated against each dialect's `compat_schema/0` at load. An optional provider module covers what flags can't, via `modify_body/4` and `modify_request/3`.

- **Two message roles only**: `:user` and `:assistant`. No `:tool` role — tool results are `Content.ToolResult` blocks inside user messages.

- **Recursive stream loop**: `Omni.Loop` handles tool auto-execution and structured output validation via recursive `Stream.flat_map`. `stream_text/3` always delegates to `Loop.stream/3`. Tools execute in parallel via `Tool.Runner.run/3`. `:max_steps` (default `:infinity`) caps rounds. When `:output` is set, the loop validates against the schema and retries up to 3 times on failure.

- **Dialect behaviours**: `Omni.Dialect` is the base (`auth/0`, `compat_schema/0`, registry, `compat/2`, `capability/1`); `Omni.Dialect.Text` and `Omni.Dialect.Decision` hold the capability callbacks. `use Omni.Dialect, :text | :decision` declares both. A dialect serves exactly one capability.

- **Decisions**: `%Omni.Decision{state, questions, answers, usage, model, raw}` is both request and result. Questions and answers are keyword lists of structs (`Omni.Question.{Predicate,Choice,Score}`, `Omni.Answer.{Predicate,Choice,Score,Refusal}`), answers aligned with questions; probabilities are `[{key, float}]` in the caller's keys and order, passed through unrounded. Validated once by `Decision.validate/1` (the floor every host accepts; caps are left to the provider). A missing, extra or mistyped answer is `{:error, {:invalid_answer, name}}`.

- **Single validation pass**: `Request.validate/3` merges the shared config schema (+ the text schema for text) + dialect option schemas, merges the provider's `api_key`/`headers` (which already absorbed app config) with call-site opts, and validates via Peri in one pass.

### Module layout

```
lib/omni.ex                         # Top-level API: generate_text, stream_text, decide, get_model
lib/omni/
├── application.ex                  # Boots Omni.Provider.Loader at startup
├── model.ex                        # Model struct
├── context.ex                      # Context struct (system, messages, tools)
├── message.ex                      # Message struct (role, content blocks, timestamp)
├── response.ex                     # Response struct (wraps Message + metadata)
├── streaming_response.ex           # StreamingResponse + Enumerable impl
├── usage.ex                        # Usage struct (tokens + computed costs, price/2)
├── decision.ex                     # Decision struct (request and result) + validation
├── question.ex, question/*.ex      # Question constructors + Predicate/Choice/Score structs
├── answer.ex, answer/*.ex          # Answer structs (Predicate/Choice/Score/Refusal)
├── tool.ex                         # Tool struct, behaviour, use macro
├── tool/runner.ex                  # Parallel tool execution (ToolUse → ToolResult)
├── schema.ex                       # JSON Schema builders, validation, key normalization
├── schema/adapter.ex               # Behaviour for alternative schema validators
├── codec.ex                        # Lossless struct ↔ JSON-safe map serialisation
├── util.ex                         # Shared helpers (maybe_put, maybe_merge)
├── content/{text,thinking,attachment,tool_use,tool_result}.ex
├── parsers/sse.ex                  # SSE stream parser
├── parsers/ndjson.ex               # NDJSON stream parser (Ollama)
├── request.ex                      # Request orchestration (build, stream, send, validate, parse_event)
├── loop.ex                         # Recursive stream loop (tool auto-execution)
├── verify.ex                       # Live verification runner behind mix omni.verify and the sweep
├── verify/scenarios.ex             # Verify's scenario requests, shared with capture scripts and tests
├── provider.ex                     # Provider struct + module behaviour + get/load/resolve_auth
├── provider/builtins.ex            # Built-in provider ids → modules
├── provider/endpoint.ex            # Endpoint struct (base_url, compat) + host: helpers
├── provider/loader.ex              # Assembly, merging, validation, store, boot config checks
├── providers/{anthropic,openai,ollama,opencode,...}.ex   # Built-in provider modules
├── source.ex                       # Source behaviour + build_model/1 + endpoints/3 + memo cache
├── sources/{models_dev,llmdb}.ex
├── dialect.ex                      # Base dialect behaviour + `use` + string→module registry + compat/2 + capability/1
├── dialect/{text,decision}.ex      # Capability behaviours
├── dialect/decision/answers.ex     # Shared answer matching for decision dialects
├── dialect/thinking.ex             # Shared :thinking resolution (effort clamping, budgets)
└── dialects/{anthropic_messages,openai_completions,openai_responses,google_gemini,ollama_chat,system_one,openai_decisions}.ex
lib/mix/tasks/omni.{snapshot,verify}.ex
```

## Conventions

- All public API functions return `{:ok, result} | {:error, reason}` tuples.
- Content blocks, questions and answers are separate structs under `Omni.Content`, `Omni.Question` and `Omni.Answer` — pattern match on struct name, not a type field.
- A provider's id is its models.dev catalog key snake_cased as an atom (e.g. `:moonshotai`, `:ollama_cloud`). The id is the single identity: config keys, `get_model/2` lookup, and source catalog lookup all use it (sources translate to their native key format themselves). There is no renaming; an id the catalog doesn't know is a custom provider defined in config.
- `config :omni, :models` selects: `providers:` (ids, `:builtins` expanding to `Omni.Provider.Builtins`), `source:`, `filter:`. `config :omni, :providers` configures by id: `name`, `host`, `api_key`, `auth`, `headers`, `dialects`, `module`, `models`, `source`. Configuring never enables. Endpoints go under `dialects: %{Module => [base_url: url, compat: [...]]}` — `base_url` is the whole URL incl. the version segment (dialect paths are resource paths only); `[]` declares a dialect; `compat: [like: :builtin_id, ...]` copies a built-in's flags for that dialect. `host:` is an origin only (`scheme://host[:port]`): it moves every source/module endpoint URL at load (app-config URLs are used as written) or one request's URL at the call site, keeping paths. Merge rule: values replace; `headers` merge by key, `dialects` by module then field (`base_url` replaces, `compat` by flag), `models` by id then field — a config model with a catalog id merges over it, a new id is added and names its dialect. v1-style config (provider `base_url:`, top-level `compat:`, `dialects: %{text: ...}`) raises at boot with a migration message.
- Provider modules declare `@behaviour Omni.Provider`; every callback is optional (`config/0`, `models/2`, `modify_request/3`, `modify_body/4`). Modules carry no id — built-ins are mapped in `Omni.Provider.Builtins`, others are attached with `module:` in config. Built-in modules set their endpoint URL and compat under `dialects:`, and `api_key`, explicitly in `config/0` (OpenCode takes its URLs from the catalog). Stamp, don't invent: a module may add a capability to a catalog model (OpenAI's `gpt-6-luna`) or list models for a provider the catalog lacks (TypeSafe, local Ollama), never add models to a provider the catalog knows.
- API key resolution: call-site `:api_key` opt → provider value (source, module, app config). Accepts literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}`.
- Store: `{Omni, :providers}` holds `%{id => %Provider{}}`; `{Omni, :models, id}` holds `%{model_id => %Model{}}`. Writes go through the Loader. Unknown or unloaded providers return `{:error, {:unknown_provider, id}}`.
- Tool modules use `use Omni.Tool, name: "string", description: "string"`. The `name:` and `description:` options are optional — omit them to implement `name/0` and `description/0` as callbacks directly. Override `description/1` to incorporate `init/1` state into the description. Import `Omni.Schema` inside the `schema/0` callback, not at module level.
- The term is "tool use", not "tool call" (aligns with Anthropic's API).
- Attachment sources use tagged tuples: `{:base64, data}` or `{:url, url_string}`.
- `Message.private` is a `%{}` map for provider-specific opaque round-trip data. Dialects/providers write during parsing, read during encoding. Flat atom keys.
- `Message.origin` is `%{model: {provider_id, model_id}, dialect: module}` on assistant messages Omni produced (stamped by `StreamingResponse`), else `nil`. `Request.build/3` strips thinking, signatures and `private` from assistant messages whose origin differs from the target's provider or dialect, or is `nil`, before the dialect encodes; dialects never see foreign replay data.
- Content blocks may carry a `signature` field (round-trip integrity tokens). `Thinking.redacted_data` holds Anthropic's encrypted redacted thinking — when present, `text` is `nil`. Provider-specific data goes in `Message.private`, not on content blocks.
- Struct constructors (`new/1`) return bare structs without validation. Validation happens once at the API boundary via Peri schemas.
- `Omni.Schema` preserves property key types as-is. Snake_case option keywords normalize to camelCase JSON Schema keywords.
- `Tool.execute/2` validates and casts input via Peri before calling the handler — string-keyed LLM input maps back to schema key types.
- `Model.thinking` is `false`, `true` (reasons, no detail), or `%{efforts, toggle, budget}` from catalog `reasoning_options`. Dialects translate the `:thinking` option through `Omni.Dialect.Thinking.resolve/2` (shared clamping and budgets); no dialect matches on model-name prefixes for thinking. `thinking: true` is `:medium` everywhere (no dynamic mode).
- Compat flags are named by wire shape or Omni concept, never by provider; absent means the dialect's home-API behaviour. A flag ships only with a built-in provider that uses it.
- A **capability** is a kind of request (`:text`, `:decision`): the keys of `Model.dialects`, read with `Model.capabilities/1`, `capability?/2` and `dialect/2`. A **modality** is a kind of content (`:text`, `:image`, `:pdf`). Don't mix the terms; `:text` is both. Thinking and tool use are text features; every catalog text model supports tool use (sources filter out the rest).
- Supported modalities defined on `Omni.Model`. Input: `:text`, `:image`, `:pdf`. Output: `:text` (a decision's answers count as text).
- Structured output wire format is dialect-specific. Each dialect applies its own strictness mechanism.
- `%Response{}` carries `messages`, `usage`, and `stop_reason` (includes `:cancelled`). `:message` is optional.
- Filesystem path naming: `*_dir` for directories, `*_file` for files, `*_path` for generic or non-filesystem paths (e.g. URL paths). Applies to config keys, function params, variables, and module attributes.

## Testing

Two jobs, kept apart. **Tests** check that Omni handles real wire bytes: offline, in CI, replaying recorded fixtures. **Verify** (`mix omni.verify`, and the sweep over it) checks that a provider's current models work today: live calls only, run by the maintainer. A fixture can't say a provider works today; verify can't guard against regressions. `context/design.md` (Verification and testing) has the detail.

1. **Unit tests** (`test/omni/`) — pure logic, no HTTP. Parser, provider, and dialect tests in isolation. Build structs with `Omni.Test.Fixtures`; assemble providers with `Omni.Provider.Loader.assemble/2` (never writes the store) rather than loading them.
2. **Integration tests** (`test/integration/`) — replay fixtures through the top-level API with a `Req.Test` plug (`Omni.Test.Capture.replay/4`). Three tiers, each fixture in the lowest tier where it is the only real bytes for some parsing path:
   - **Omni** — `loop_test`, `error_test`, `structured_output_test`: `StreamingResponse` and `Loop`, on Anthropic fixtures plus `fixtures/synthetic/`.
   - **Dialect** — `dialects/<dialect>_test.exs`: parser paths any provider on the dialect takes, recorded from the dialect's home API (`Omni.Test.Cases.reference/1`).
   - **Provider** — `<provider>_test.exs`: a `baseline` block (text, thinking, tool use, request target and request shape, via `Omni.Test.Baseline`; for decision models the `decision` and `decision_json` scenarios), then `cases` and `synthetic` blocks only for genuine quirks.

**Fixtures** live in `test/support/fixtures/<provider id>/` and `fixtures/dialects/<dialect>/`, each directory with a `capture.exs` that records it (`.sse` or `.ndjson` for text, `.json` for decisions). `Omni.Test.Capture.record/4` makes one request per fixture, skips files that exist (delete one to re-record it) and replays what it wrote. Baseline requests come from verify's scenarios (`Omni.Verify.Scenarios`), so a baseline fixture is a recording of what verify checks; other cases' requests are in `Omni.Test.Cases`. Tests look models up from the catalog: when a snapshot refresh drops one, re-record on a current model. Hand-written synthetic fixtures cover errors and edge cases no API produces on demand.

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
