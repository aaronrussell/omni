# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Tool Calling Loop

**Status:** Implemented. See `Omni.Loop` and the CLAUDE.md "Recursive stream loop" section for details.

---

## Structured Output

**Status:** Implemented. The `:output` option on `stream_text/3` / `generate_text/3` sends a JSON Schema to the provider for constrained decoding. `Omni.Loop` validates the response (JSON decode + Peri validation) and retries up to 3 times on failure. Each dialect handles wire format independently — see CLAUDE.md conventions for details.

---

## Pre-v1 Checklist

- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — Review all `@moduledoc`, `@doc`, and `@typedoc` annotations. Ensure top-level API functions have examples. Check ExDoc output.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_input_modalities`.
- **Agent capabilities** — Goal-orientation, hooks, error recovery, observability. Needs further design work.
