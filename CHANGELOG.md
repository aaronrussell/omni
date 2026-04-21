# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Z.ai structured output** — rewrites `json_schema` response format to `json_object` with the schema appended to the system prompt, working around Z.ai's lack of native JSON Schema support.
- **Z.ai provider** — opt-in built-in provider speaking the OpenAI Chat Completions dialect. Rewrites the dialect's `/v1/` path to Z.ai's `/v4/` endpoint, and translates the standard `:thinking` option onto Z.ai's `thinking: %{type: "enabled" | "disabled"}` parameter (effort levels are flattened to on/off — Z.ai exposes no granularity).
- **Groq provider** — opt-in built-in provider speaking the OpenAI Chat Completions dialect. Normalises Groq's per-family `reasoning_effort` quirks: clamps `:xhigh`/`:max` to `"high"` on `openai/gpt-oss-*` models, and rewrites any positive effort to `"default"` on `qwen/qwen3-32b` (which only accepts `"none"` or `"default"`).
- **`Omni.Codec`** — lossless encode/decode of `Message`, content blocks, and `Usage` to JSON-safe maps for downstream persistence layers. Opaque fields (`Message.private`, `Attachment.meta`) and arbitrary terms round-trip via base64-encoded ETF with safe decoding.
- **Updated model catalog** — refreshed model data across Anthropic, Google, Ollama Cloud, OpenAI, OpenCode, and OpenRouter.
- **New `:xhigh` thinking level** — slotted between `:high` and `:max`. Maps directly to `"xhigh"` on Anthropic adaptive and OpenAI reasoning models, with graceful downgrades elsewhere.
- **Claude Opus 4.7 support** — routes through the adaptive thinking path, strips non-default `temperature`/`top_p`/`top_k` unconditionally (4.7 now rejects them), and sends `display: "summarized"` on adaptive requests so thinking text continues to stream back.
- **Gemini 3 thinking** — shifted mapping onto `thinkingLevel` (`:low → "minimal"` … `:max → "high"`) so the provider's full range is addressable. Gemini 2.5 models continue to use `thinkingBudget` with sensible level → integer mappings.
- **Standardised live test suite** — extracted shared test helpers into `LiveTests` module covering text generation, thinking, tool use, structured output, image/PDF vision, and roundtrip. All 8 providers (Anthropic, Google, OpenAI, OpenRouter, OpenCode, Ollama, Groq, Z.ai) run through the same assertions.

### Fixed

- **OpenAI Completions tool call parsing** — arguments were silently dropped when a provider sent tool name and arguments in a single streaming event (affected Groq and Z.ai).
- **OpenAI structured output** — both Completions and Responses dialects now apply `additionalProperties: false` on object schemas, fixing 400 errors from OpenAI's strict mode requirement.
- **OpenAI Responses PDF attachments** — added missing `filename` field on `input_file` content blocks, fixing 400 errors when sending PDF attachments.
- **Google Gemini signature-only thinking** — `thoughtSignature` with empty text now attaches the signature to the text block instead of creating a phantom thinking block.
- **Groq reasoning format** — `reasoning_format: "parsed"` is now only sent when reasoning effort is set, avoiding errors on non-reasoning models.
- **Google Gemini API version** — hardcoded `v1beta` path prefix, as many features (structured output, thinking) require the beta API.

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

[Unreleased]: https://github.com/aaronrussell/omni/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/aaronrussell/omni/releases/tag/v1.2.1
[1.2.0]: https://github.com/aaronrussell/omni/releases/tag/v1.2.0
[1.1.0]: https://github.com/aaronrussell/omni/releases/tag/v1.1.0
[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
