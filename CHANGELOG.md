# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Updated model catalog** — refreshed across all providers. Includes Kimi K3.

### Fixed

- **Sequential block closure in `StreamingResponse`** — block `*_end` events (e.g. `thinking_end`, `text_end`) are now emitted inline when the next block starts, rather than bunched at stream finalization. In multi-block responses (thinking+text, text+tool_use), a block's end event now always precedes the next block's start event.

## [1.6.1] - 2026-07-10

### Added

- **Updated model catalog** — refreshed across all providers. Captures GPT-5.6 family (Sol, Terra, Luna).

## [1.6.0] - 2026-07-06

### Added

- **Pluggable model sources** — model catalog data now loads through the new `Omni.Source` behaviour, configurable globally or per provider.
- **`Omni.Sources.ModelsDev`** — the default source: a bundled [models.dev](https://models.dev) snapshot, with an optional live mode (`live: true`) that fetches fresh catalog data at boot and degrades gracefully to the snapshot when offline.
- **`Omni.Sources.LLMDB`** — alternative source backed by the optional [`llm_db`](https://hex.pm/packages/llm_db) package.
- **`Omni.Providers.OllamaCloud`** — new provider for Ollama's hosted cloud service (`:ollama_cloud`, reads `OLLAMA_API_KEY`).

### Changed

- **Providers declare a canonical id** (breaking) — `use Omni.Provider, id: :mistral`, named after the provider's models.dev catalog key (snake_cased). The id drives registration, `Omni.get_model/2`, and catalog lookup, and `models/0` now defaults to loading from the configured source — a catalog-backed custom provider needs only `id:` and `config/0`.
- **Provider config moved to `config :omni, :models`** (breaking) — registration goes under `providers:` (a list of provider modules; `:builtins`, the default, names the built-ins and may appear in the list), the model source under `source:`. The legacy `:providers` key raises at boot with migration instructions.
- **`:moonshot` is now `:moonshotai`** (breaking), matching the catalog id.
- **Ollama split into local and cloud providers** (breaking) — `Omni.Providers.Ollama` (`:ollama`) now targets local instances only, with models listed in its `models:` config. Cloud users switch to `Omni.Providers.OllamaCloud` (`:ollama_cloud`).
- **Dialect resolution is now data-first** — a model's dialect from catalog data wins over the provider module's declared dialect, which is now a fallback. No behavior change for built-in providers.
- **`Omni.Provider.load_models/2`** (breaking) — takes options instead of a JSON file path. The curated `priv/models/*.json` files are replaced by the verbatim snapshot, captured with the new `mix omni.snapshot` task.

### Removed

- **Legacy mix tasks** — `mix models.update` and `mix models.update_llmdb`.

## [1.5.4] - 2026-06-25

### Added

- **Updated model catalog** — refreshed across all providers.

## [1.5.3] - 2026-06-16

### Added

- **Updated model catalog** — refreshed across all providers.

## [1.5.2] - 2026-06-02

### Added

- **Updated model catalog** — refreshed across all providers. Notable additions: Claude Opus 4.8, Minimax M3.

## [1.5.1] - 2026-05-22

### Added

- **NEAR AI Cloud provider** — built-in provider for NEAR AI Cloud's OpenAI-compatible API, including TEE-backed inference models.
- **Updated model catalog** — refreshed across all providers.

## [1.5.0] - 2026-05-18

### Added

- **Updated model catalog** — refreshed across all providers.

### Changed

- **All built-in providers loaded by default** — all 11 built-in providers are now available out of the box without configuration. The `config :omni, :providers` option can still be used to restrict which providers load at startup.

### Fixed

- **Prompt cache usage tokens** — `cache_read_tokens` and `cache_write_tokens` on `%Usage{}` were always zero for non-Anthropic providers. All dialects now correctly report prompt cache hits from their respective APIs.

## [1.4.1] - 2026-05-11

### Added

- **Venice AI provider** — opt-in built-in provider for Venice AI's hosted models.
- **Updated model catalog** — refreshed across all providers.

## [1.4.0] - 2026-05-08

### Added

- **`Omni.Schema.Adapter` behaviour** — pluggable schema validators. Pass a `{module, state}` tuple anywhere a JSON Schema map is accepted (`:output` option, `Tool` `input_schema`, tool `schema/0` callback) to delegate wire encoding and validation to a custom adapter. Enables JSV, Ecto, or other validators with zero new dependencies in Omni itself.
- **`Omni.Schema.to_schema/1`** — public dispatcher that returns the wire-form JSON Schema map for a raw schema or adapter tuple.
- **`Omni.Tool` `schema/1` callback** — state-aware variant of `schema/0` for tools whose input schema depends on init state. Mirrors the existing `description/0,1` pattern; the default `schema/1` delegates to `schema/0`, so existing tools are unaffected.
- **Updated model catalog** — refreshed across all providers.

### Changed

- **`Omni.Tool` `description/0` and `schema/0` are no longer required when implementing the 1-arity variant** — the macro now generates raising defaults (matching `call/1,2`), so a tool can implement just `description/1` or `schema/1` without compiler warnings.
- **`Omni.Schema` is now the default `Omni.Schema.Adapter`** — `to_schema/1` and `validate/2` accept either a raw map or an adapter tuple and dispatch accordingly.
- **`Omni.Schema.validate/2` return shape** — now returns `{:ok, term()} | {:error, String.t()}` consistently. Errors come back as a pre-formatted human-readable string instead of a list of Peri error structs.
- **Built-in validator** — replaced internal Peri schema converter with `Peri.from_json_schema/1` (peri bumped to `~> 0.8`).

### Fixed

- **JSON Schema constraints now enforced** — `multipleOf`, `minItems`, `maxItems`, `uniqueItems`, `const`, `null`, `oneOf`, `allOf`, union types, and string `format` are validated locally where previously they were silently skipped.
- **`number` type accepts integers** — schemas with `{"type": "number"}` now accept integer inputs as required by the JSON Schema spec (previously rejected).

## [1.3.2] - 2026-05-01

### Added

- **Updated model catalog** — refreshed across all providers, including GPT-5.5 Pro and Deepseek v4 Pro.

## [1.3.1] - 2026-04-27

### Added

- **Alibaba provider** — opt-in built-in provider for Alibaba Cloud's hosted models.
- **Updated model catalog** — refreshed across all providers, including GPT-5.5 and Deepseek v4 (OpenRouter).

## [1.3.0] - 2026-04-21

### Added

- **Groq provider** — opt-in built-in provider for Groq's hosted models.
- **Moonshot AI provider** — opt-in built-in provider for Moonshot's Kimi models.
- **Z.ai provider** — opt-in built-in provider for Z.ai.
- **`Omni.Codec`** — lossless encode/decode of messages, content blocks, and usage to JSON-safe maps for persistence.
- **`:xhigh` thinking level** — new level between `:high` and `:max`.
- **Claude Opus 4.7 support** — full support including adaptive thinking.
- **Updated model catalog** — refreshed across all providers, including Claude Opus 4.7 and Kimi K2.6.

### Changed

- **Google Gemini API version** — now defaults to `v1beta` unconditionally, removing the previous `v1`/`v1beta` option.

### Fixed

- **OpenAI Completions tool use parsing** — arguments were dropped when name and arguments arrived in a single streaming event.
- **OpenAI structured output** — `additionalProperties: false` now applied on object schemas for strict mode compatibility.
- **OpenAI Responses PDF attachments** — added missing `filename` field on file content blocks.
- **Google Gemini API version** — hardcoded `v1beta` path prefix, as many features require the beta API.

## [1.2.1] - 2026-04-02

### Added

- **Dynamic tool descriptions** — Override `description/1` to incorporate `init/1` state into the tool description at construction time.

### Fixed

- **Google Gemini structured output** — auto-upgrade to `v1beta` API when `:output` is set, fixing 400 errors caused by `responseMimeType`/`responseSchema` fields not existing in `v1`.

## [1.2.0] - 2026-03-23

### Added

- **`release_date` on `%Model{}`** — optional `Date.t()` field populated from models.dev release date data. Enables filtering models by release date.
- **New models** — GPT-5.4 Mini and GPT-5.4 Nano added to model data.

### Removed

- **Agent extracted** — `Omni.Agent`, `Omni.Agent.*`, and `Omni.MessageTree` have been extracted into the standalone [`omni_agent`](https://github.com/aaronrussell/omni_agent) package. This package is now purely the stateless LLM API layer.
- **`%Turn{}` struct removed** - `Loop` `:turn_id` and `:turn_parent` options removed.

### Changed

- **`%Attachment{}`** — removed unused `description` field. Renamed `opts` to `meta` — an application-layer map that dialects do not read or send to providers (e.g. for filenames or display labels).
- **`%Response{}`** — `turn` field replaced by `messages` (list), `usage` (`%Usage{}`), and `node_ids` (list of tree node IDs, used by `omni_agent`). `:message` is now optional. Added `:cancelled` stop_reason.

## [1.1.0] - 2026-03-06

### Added

- **`%Turn{}` struct** — a conversation turn carrying messages, usage, and tree position (`id`, `parent`). Used as tree nodes in `MessageTree` and on `Response` for accumulated generation data.
- **`MessageTree`** — tree-structured conversation history with branching, navigation, and `Enumerable` support.
- **Agent conversation tree** — agents manage a `%MessageTree{}` internally. State restructured around `system`, `tools`, `tree`, `meta`, `private` fields. `assigns` replaced by `meta` (user data) + `private` (runtime state).
- **`Agent.set_state/2,3`** — replace agent configuration fields (model, system, tools, tree, opts, meta). Always replaces, atomic, idle-only. `/3` accepts a value or updater function.
- **`Agent.navigate/2`** — set the active conversation path to any turn in the tree.
- **`Agent.usage/1`** — cumulative token usage across all turns in the tree.
- **Turn data on agent events** — `:turn` and `:done` events carry a `%Turn{}` with tree position, enabling external persistence without built-in storage.
- **`tree:` start option** — hydrate an agent with a pre-built `%MessageTree{}`.
- **`Model.to_ref/1`** — convert a resolved `%Model{}` back to its `{provider_id, model_id}` lookup reference.

### Changed

- **`%Response{}`** — `messages` and `usage` fields replaced by `turn` field containing a `%Turn{}`. Access via `response.turn.messages` and `response.turn.usage`.

### Fixed

- **OpenAI Completions dialect** — tool use name lost when provider sends `id` on every SSE chunk (affected Kimi models via OpenCode/Fireworks).

## [1.0.0] - 2026-03-06

Complete rewrite of Omni as a production-ready, multi-provider LLM client for Elixir.

### Added

- **Text generation** — `generate_text/3` and `stream_text/3` top-level API.
- **Streaming** — `StreamingResponse` implementing `Enumerable` with composable event handlers, text stream extraction, cancel support, and incomplete stream detection.
- **Tool use** — define tools with JSON schemas and handlers; automatic execution loop runs tools in parallel and feeds results back to the model.
- **Agents** — `Omni.Agent` GenServer for stateful multi-turn conversations with lifecycle callbacks, tool approval flow, pause/resume, and prompt queuing/steering.
- **Structured output** — constrained decoding via JSON Schema with per-dialect wire format handling and automatic validation/retry.
- **Providers** — behaviour-based provider system with six built-in providers
  - Anthropic, OpenAI, Google Gemini, OpenRouter, Ollama, OpenCode Zen
  - Multi-dialect provider support for gateways that serve models with different wire formats
- **Dialects** — wire format translation separated from provider identity
  - Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, Google Gemini, Ollama Chat
- **Model catalog** — hundreds of models loaded from bundled JSON data (sourced from [models.dev](https://models.dev)) at startup.
- **Messages and content** — two-role message model (`:user`, `:assistant`) with typed content blocks: `Text`, `Thinking`, `Attachment`, `ToolUse`, `ToolResult`

---

*Versions 0.1.0 and 0.1.1, released in 2024, were early prototypes with a different architecture. Version 1.0 is a complete rewrite and is not compatible with 0.1.x.*

[Unreleased]: https://github.com/aaronrussell/omni/compare/v1.5.3...HEAD
[1.5.4]: https://github.com/aaronrussell/omni/releases/tag/v1.5.4
[1.5.3]: https://github.com/aaronrussell/omni/releases/tag/v1.5.3
[1.5.2]: https://github.com/aaronrussell/omni/releases/tag/v1.5.2
[1.5.1]: https://github.com/aaronrussell/omni/releases/tag/v1.5.1
[1.5.0]: https://github.com/aaronrussell/omni/releases/tag/v1.5.0
[1.4.1]: https://github.com/aaronrussell/omni/releases/tag/v1.4.1
[1.4.0]: https://github.com/aaronrussell/omni/releases/tag/v1.4.0
[1.3.2]: https://github.com/aaronrussell/omni/releases/tag/v1.3.2
[1.3.1]: https://github.com/aaronrussell/omni/releases/tag/v1.3.1
[1.3.0]: https://github.com/aaronrussell/omni/releases/tag/v1.3.0
[1.2.1]: https://github.com/aaronrussell/omni/releases/tag/v1.2.1
[1.2.0]: https://github.com/aaronrussell/omni/releases/tag/v1.2.0
[1.1.0]: https://github.com/aaronrussell/omni/releases/tag/v1.1.0
[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
