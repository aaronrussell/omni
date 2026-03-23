# Omni Roadmap

**Last updated:** March 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.
- **`Omni.Codec`** — Lossless encode/decode for Omni structs to plain maps (for JSON/JSONB storage). Was specified in detail in the removed `context/sessions.md`. Not tied to any agent storage — standalone utility for applications that persist conversations. Can be re-derived from struct definitions when needed.
