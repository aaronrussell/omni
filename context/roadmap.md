# Omni Roadmap

**Last updated:** March 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Pre-v1 Checklist

- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.


---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Attachment opts** — `Attachment.opts` is reserved for provider-specific metadata (Anthropic: context/title/citations, OpenAI Responses: file_id/file_name). Dialects don't read from it yet. Wire up dialect encoding to pass through relevant opts, or remove the field if the standardised attachment surface proves sufficient.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.
