# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Open Questions

1. **Automated tool calling loop** — Distinct functions that loop over single-request primitives. Needs design work: should it be a simple recursive function, a configurable loop with hooks, or something more structured? How does cancellation/max-iterations work? How are tool execution errors surfaced?

## Pre-v1 Checklist

- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — Review all `@moduledoc`, `@doc`, and `@typedoc` annotations. Ensure top-level API functions have examples. Check ExDoc output.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_input_modalities`.
- **Agent capabilities** — Goal-orientation, hooks, error recovery, observability. Needs further design work.
