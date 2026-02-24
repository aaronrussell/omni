# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Tool Calling Loop

**Status:** Implemented. See `Omni.Loop` and the CLAUDE.md "Recursive stream loop" section for details.

---

## Structured Output

**Status:** Not yet designed. Capture here for future reference.

Structured output would allow the model to return data conforming to a schema. Likely API shape: an `output:` option on `stream_text/3` / `generate_text/3` rather than separate `stream_object` / `generate_object` functions (same rationale as the tool loop — avoid function proliferation).

This has a looping element: validate the generated output against the schema, and if invalid, feed the validation error back to the model and retry. Analogous to the tool loop but with a different trigger — schema validation failure instead of tool use. A `max_retries:` option (distinct from `max_steps:`) would govern this. Both loops use the same underlying append-to-context-and-retry machinery, and they may compose: a call with tools AND structured output could tool-loop several times, then validate the final output against the schema.

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
