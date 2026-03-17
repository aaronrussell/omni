# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`%Turn{}` struct** — wraps messages and usage for a conversation turn. Used in `%MessageTree{}` as tree nodes and on `%Response{}` to carry accumulated messages, usage, and tree position (`id`, `parent`). Enables external listeners to reconstruct conversation trees for persistence.
- **MessageTree** — tree-structured conversation history for branching, regeneration, and navigation. Pure functional data structure with `Enumerable` implementation. Stores `%Turn{}` structs keyed by `Turn.id()`.
- **`Agent.set_state/2,3`** — replaces `configure/2,3`, `add_tools/2`, and `remove_tools/2`. Always replaces (no merge), works with all settable fields (`:model`, `:system`, `:tools`, `:tree`, `:opts`, `:meta`). Atomic — bad model resolution rolls back all changes. `/3` accepts a value or updater function.
- **`Agent.navigate/2`** — set the active conversation path to any turn in the tree. Enables rewind, branch switching, and regeneration. Returns the updated tree for immediate UI rendering.
- **`Agent.usage/1`** — compute cumulative token usage across all turns in the conversation tree.
- **Agent `meta` field** — user metadata (title, tags, domain data) on agent state, separate from runtime state. Set via `:meta` start option or `set_state/2,3`.
- **`tree:` start option** for `Agent.start_link` — accepts a pre-built `%MessageTree{}` for session hydration from application-managed storage.
- **Turn data on agent events** — `:turn` and `:done` events carry a `%Response{}` with a `%Turn{}` containing correct `id`, `parent`, `messages`, and `usage`. External listeners can persist conversation history without the agent knowing about storage.
- **`:turn_id` and `:turn_parent` options** on `stream_text`/`generate_text` — place a generation's Turn within a manually managed conversation tree (defaults: `0` and `nil`).

### Changed

- **Agent state restructure** — `%Context{}` on agent state replaced with `%MessageTree{}`. System prompt, tools, and messages are now managed separately: `state.system`, `state.tools`, `state.tree`. Context is built transiently for each LLM request.
- **`assigns` split into `meta` + `private`** — `meta` holds user data. `private` holds runtime state (PIDs, refs). `init/1` return populates `private`.
- **`%Response{}`** — `messages` and `usage` fields replaced by a single `turn` field containing a `%Turn{}`. Access via `response.turn.messages` and `response.turn.usage`.
- **`%MessageTree{}`** — rounds renamed to turns. `rounds` field is now `turns`, `get_round` is `get_turn`, `round_count` is `turn_count`. `push/3` returns `{%Turn{}, tree}` instead of `{round_id, tree}`.
- **`Context.push/2`** — reads from `response.turn.messages` instead of `response.messages`.
- **Usage no longer cached on agent state** — removed `state.usage` field. Use `Agent.usage/1` instead, which computes the total from the conversation tree.

### Removed

- **`Agent.configure/2,3`** — use `Agent.set_state/2,3` instead.
- **`Agent.add_tools/2`, `Agent.remove_tools/2`** — use `Agent.set_state(agent, tools: [...])` or `Agent.set_state(agent, :tools, fn tools -> ... end)`.
- **`Agent.clear/1`** — use `Agent.set_state(agent, tree: %MessageTree{})`.
- **Agent `session_id`** — removed from `Agent.State`. Session identity is an application concern, not an agent concern.

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
