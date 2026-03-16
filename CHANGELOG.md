# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **MessageTree** — tree-structured conversation history for branching, regeneration, and navigation. Pure functional data structure with `Enumerable` implementation.
- **Agent session identity** — agents now have a `session_id` (auto-generated or caller-provided) that changes on `clear/1`.
- **`Agent.configure/2,3`** — update model, system prompt, opts, or meta while idle. Atomic (bad model resolution rolls back all changes). `/3` accepts an updater function for `:opts` and `:meta`.
- **`Agent.navigate/2`** — set the active conversation path to any round in the tree. Enables rewind, branch switching, and regeneration. Returns the updated tree for immediate UI rendering.
- **`Agent.usage/1`** — compute cumulative token usage across all rounds in the conversation tree.
- **Agent `meta` field** — serializable user metadata (title, tags, domain data) on agent state, separate from runtime state. Set via `:meta` start option or `configure/2,3`.

### Changed

- **Agent state restructure** — `%Context{}` on agent state replaced with `%MessageTree{}`. System prompt, tools, and messages are now managed separately: `state.system`, `state.tools`, `state.tree`. Context is built transiently for each LLM request.
- **`assigns` split into `meta` + `private`** — `meta` holds serializable user data (persisted by future storage layer). `private` holds runtime state (PIDs, refs). `init/1` return populates `private`.
- **`Agent.clear/1`** now returns `{:ok, session_id}` (was `:ok`). Generates a new session ID and replaces the tree entirely, rather than just clearing messages.
- **Usage no longer cached on state** — removed `state.usage` field. Use `Agent.usage/1` instead, which computes the total from the conversation tree.

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

[Unreleased]: https://github.com/aaronrussell/omni/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
