# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Open Questions

1. **Plain text attachment source** — Should `Attachment.source` support `{:text, content}` in addition to `{:base64, data}` and `{:url, url}`? Wait to see if multiple providers support it.

2. **StreamingResponse consumption patterns** — Can consumers process structured events (tool_use_start, thinking, etc.) AND simultaneously feed a text stream to the UI with the current single-enumerable API, or do we need tee/fork/broadcast?

3. **Attachment media type validation** — Dialects crash on unsupported media types (e.g. passing an audio file to a provider that only supports images/PDFs). Needs validation at the API boundary before reaching dialect code.

4. **OpenRouter `reasoning_details` round-trip** — The `modify_events/2` hook exists but OpenRouter still uses the default passthrough. Three gaps: (a) OpenRouter needs a `modify_events/2` override to extract `reasoning_details` from raw SSE events into `{:message, %{private: ...}}` deltas, (b) Completions `encode_message/1` ignores `Message.private` — needs to encode `reasoning_details` back into the wire format on assistant messages, (c) no integration tests for either direction (SSE fixtures already contain the data).

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Automated tool calling loop** — distinct functions that loop over single-request primitives.
- **Agent capabilities** — goal-orientation, hooks, error recovery, observability. Needs further design work.
