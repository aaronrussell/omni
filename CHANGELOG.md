# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/aaronrussell/omni/releases/tag/v1.0.0
