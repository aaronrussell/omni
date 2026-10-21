# Verification — where we got to

*2026-10-21. Captured from the phase 4 scoping conversation, which concluded that verification needs its own design session. This is a starting point, not a design: directions agreed, open questions listed.*

## Why

The tiers promise rests on "verified", but verifying a provider today is ad hoc, and what we test doesn't match what can go wrong.

- **Integration tests** (`test/integration/<provider>_test.exs`, ~140 lines each, eleven nearly identical files) replay three recorded fixtures per built-in: text, thinking, tool use. One model per provider. No real-recording coverage of structured output, images or PDFs (structured output and cache usage have synthetic fixtures only, on a few dialects).
- **Live tests** (`test/live/`, `:live` tag, shared `LiveTests` helpers) run seven scenarios per provider: text, thinking, tool use, structured output, image, PDF, round trip. Still one hard-coded model each, and not every model supports every scenario. Excluded by default and rarely run.
- **Fixture capture** (`scripts/capture_fixtures.exs`) works by commenting providers and cases in and out.
- **Models differ within a provider.** One model passing says little about the provider's other models. Neither test layer can catch that.

## Two jobs, currently mixed

- **Does Omni's code handle real wire shapes?** Offline, in CI, from recorded fixtures. Fixtures are the right tool, but they would be better organised by the shape they exercise (Completions with `reasoning_content`, with `reasoning_details`, structured output, images, …) than by "one model per provider".
- **Does this provider's current lineup work?** Live calls only. A fixture can't say the next model behaves like the last one.

Separating these is the likely basis for the rethink: integration tests become smaller and shape-targeted; verification covers model variation.

## Directions agreed

- **`mix omni.capture`** — dev-only task replacing the script: provider, model, cases as arguments; writes `<provider>_<case>.sse` (`.ndjson` for Ollama) into the fixtures directory.
- **`mix omni.verify <provider> <model>`** — shipped in the package, so users can check a catalog-tier or custom provider against their own config. Runs every applicable scenario and reports a pass/fail matrix, with request body and error for each failure, rather than stopping at the first. Works for built-in, catalog and custom providers alike. The scenarios in `LiveTests` are the starting point, rewritten as plain checks rather than ExUnit assertions.
- **Live tests retired** in favour of verify (`test/live/`, the `:live` tag, `mix test --include live` in `CLAUDE.md`). `scripts/test_loop.exs` and `test_output.exs` likely go too if verify covers them.
- **Sweep script** — run locally with real keys, now and then. A maintained map of models, each with the scenarios to check, iterated through verify. The map tracks today's common models; it doesn't try to cover every model ever.
- **Shared integration template** — something like `use Omni.Test.ProviderCase, ...` generating the standard tests, with provider-specific tests below. Subject to the rethink above.
- **The contribution path** for the verified tier falls out of this: run verify, set compat flags until it passes, capture fixtures, add the module and moduledoc. Document it once the tools exist (the `Omni.Provider` tiers section defers to it).

## Open questions

- Does verify pick scenarios from the model's own capability data (modalities, `thinking`, structured output support), so the sweep map only names models and overrides?
- Which scenarios beyond the current seven: caching, thinking at each effort level, `thinking: false` on models that can switch off, multi-step tool loops with thinking replay?
- What shape-targeted fixtures should look like, how they are named, and how many each dialect needs.
- Where the sweep map lives (`scripts/`, or alongside the verify task).
- Output format for verify: human-readable only, or also machine-readable for the sweep to summarise.
- Whether verify runs scenarios concurrently, and how it handles rate limits and cost.
