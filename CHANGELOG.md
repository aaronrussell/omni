# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/aaronrussell/omni/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/aaronrussell/omni/releases/tag/v1.3.0
[1.2.1]: https://github.com/aaronrussell/omni/releases/tag/v1.2.1
[1.2.0]: https://github.com/aaronrussell/omni/releases/tag/v1.2.0
[1.1.0]: https://github.com/aaronrussell/omni/releases/tag/v1.1.0
[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
