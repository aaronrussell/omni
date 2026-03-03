# Omni Roadmap

**Last updated:** March 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Pre-v1 Checklist

- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Revisit `:thinking` option API** — The current accepted values (`true`, `false`, `:none`, `:low`, `:medium`, `:high`, `:max`, keyword list) mix booleans and atoms in a confusing way. `false` and `:none` do the same thing; `true` is an alias for `:high`. Needs a pass across all dialects to settle on a cleaner, more intentional interface.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Namespace streaming parsers** — Move `Omni.SSE` and `Omni.NDJSON` into `Omni.Parsers.SSE` and `Omni.Parsers.NDJSON` (`lib/omni/parsers/`). Groups related internal modules by purpose for easier source navigation.
