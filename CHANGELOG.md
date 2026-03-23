# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- **Agent extracted** — `Omni.Agent`, `Omni.Agent.*`, and `Omni.MessageTree` have been extracted into the standalone [`omni_agent`](https://github.com/aaronrussell/omni_agent) package. This package is now purely the stateless LLM API layer.

### Changed

- **`%Response{}`** — `turn` field replaced by `messages` (list), `usage` (`%Usage{}`), and `node_ids` (list of tree node IDs, used by `omni_agent`). `:message` is now optional. Added `:cancelled` stop_reason.
- **`Context.push/3`** — reads `response.messages` instead of `response.turn.messages`.
- **Loop** — `:turn_id` and `:turn_parent` options removed. Response fields set directly.

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

[Unreleased]: https://github.com/aaronrussell/omni/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/aaronrussell/omni/releases/tag/v1.1.0
[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
