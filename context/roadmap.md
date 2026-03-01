# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Pre-v1 Checklist

- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — In progress. See below.

---

## Documentation

Module-only documentation for now (no extra pages/guides). The `Omni` moduledoc serves as the landing page with setup, examples, and pointers to key modules.

**Structure decisions:**
- Module groups: ungrouped top-level (Omni, Model, Tool, Schema, StreamingResponse, Tool.Runner), Agents, Data, Providers, Dialects
- Function groups on `Omni` (Text Generation, Models, Context). `Omni.Agent` is ungrouped
- Request, SSE, Loop hidden from docs (`@moduledoc false` with code comments retained)
- Tone: practical, concise, example-driven for key APIs

**Completed:** `Omni`, `StreamingResponse`, `Tool`, `Tool.Runner`, `Agent`, `Agent.State`, `Model`, `Context`, `Message`, `Response`, `Usage`, `Content.Text`, `Content.Thinking`, `Content.Attachment`, `Content.ToolUse`, `Content.ToolResult`
**Remaining:** `Schema`, `Provider`, `Dialect`, provider/dialect modules

---

## Completed

- **Tool Calling Loop** — `Omni.Loop` handles tool auto-execution and structured output validation. See CLAUDE.md.
- **Structured Output** — The `:output` option sends a JSON Schema to the provider for constrained decoding. See CLAUDE.md.
- **Agent** — `Omni.Agent` is a GenServer-based building block for stateful, long-running LLM interactions. See `context/agent.md` for the design document.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Schema snake_case key normalization** — `Omni.Schema` builder functions accept raw keyword opts and merge them as-is into the schema map. JSON Schema uses camelCase keywords (`minLength`, `maxLength`, `minItems`, etc.) which is un-idiomatic in Elixir. Add a `normalize_key/1` step in each builder that converts a known set of snake_case atoms to their camelCase equivalents (e.g. `:min_length` → `:minLength`, `:max_length` → `:maxLength`, `:min_items` → `:minItems`, `:additional_properties` → `:additionalProperties`). Unknown keys pass through unconverted, making typos visible in the output. Update `to_peri/1` to match on the camelCase keys accordingly.
