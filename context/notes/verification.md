# Verification

*2026-10-22. Design agreed in the verification session; replaces the 2026-10-21 starting-point note. Delete once the work lands and `design.md`, `CLAUDE.md` and the `Omni.Provider` tiers section describe it.*

## Why

The tiers promise rests on "verified", but verifying a provider today is ad hoc, and what we test doesn't match what can go wrong. Integration tests are eleven near-identical files replaying text, thinking and tool-use fixtures with loose assertions. Live tests run seven scenarios against one hard-coded model per provider and are rarely run. Fixture capture works by commenting providers in and out of a script.

Two jobs were mixed together:

- **Does Omni handle real wire bytes?** Offline, in CI, from recorded fixtures — the integration tests.
- **Does this provider's current lineup work?** Live calls only — `mix omni.verify`, and the sweep script over it.

A fixture can't say a provider works today; verify can't guard against regressions in CI. Each tool does one job.

## Verify

`mix omni.verify <provider> <model>` — shipped in the package, so users can check a catalog-tier or custom provider against their own config. Runs scenarios in sequence and prints a pass/fail report, with the request and error for each failure. Never stops at the first failure. Saves nothing.

The task is a thin wrapper over an internal module (`@moduledoc false`), roughly `Omni.Verify.run(model, scenarios, opts)`, which returns results as data. The sweep calls that function.

**Scenarios.** Fixed set, not chosen from model data. Defaults are text, thinking, tool use and structured output; the rest are opt-in.

| Scenario | Default | Request | Passes when |
|---|---|---|---|
| `text` | yes | simple prompt, `thinking: false` | stop `:stop`, non-empty text |
| `thinking` | yes | a question hard enough to make the model reason, `thinking: :low` | a thinking block (text or signature) and text |
| `no_thinking` | no | the same question, `thinking: false` | no thinking blocks. Only for models whose data says they can switch off (a toggle or a `"none"` effort): elsewhere Omni sends nothing and a failure only says the model reasons by default |
| `tool_use` | yes | weather tool, no handler | a `get_weather` `ToolUse`, stop `:tool_use` |
| `structured_output` | yes | object schema | `resp.output` matches the schema |
| `image` | no | the logo PNG | answer names the brand |
| `pdf` | no | the whitepaper | answer names the author |
| `kitchen_sink` | no | thinking on, two tools with handlers, a prompt needing both; then a follow-up turn over the whole history | loop completes with ≥1 tool round and text on both turns |
| `cache_usage` | no | turn 1: long system prompt + question; turn 2: same prefix + turn 1 + short follow-up | turn 2 reports cache-read tokens > 0 |

- **Pass or fail only.** No skip, no warn, no retries (Omni itself doesn't retry: Req's default retry covers only GET and HEAD). A failure on a model that can't do the scenario is correct; the sweep matrix just doesn't ask. Flaky results are investigated: tighten the prompt, or drop the scenario for that model.
- **Thinking effort levels are not verified** — no reliable way to measure the level applied.
- `kitchen_sink` replaces the old round trip and covers thinking replay (signatures, `Message.private`) across tool rounds and a later turn. Supersedes `scripts/test_loop.exs`.
- `cache_usage` exercises Omni's breakpoint placement: on turn 2 the last-message breakpoint has moved, so the hit depends on the shared prefix re-encoding byte-identically. Needs a few thousand tokens of filler in `priv/` (above every provider's minimum) and possibly a short pause between turns where caches fill asynchronously. Never verified before.
- Assets move out of `test/support`: logo, PDF and cache filler live in `priv/`.

**Flags.** `--only a,b` (exactly these), `--add a,b` / `--skip a,b` (adjust the defaults), `--delay ms` (pause between scenarios, for rate limits).

**Output.** Each result line carries a short, generic reason (`HTTP 429`, `stream error`, `no thinking`), never provider text. Failures from an error print the full error after the run. Request bodies aren't shown.

## Sweep

A script (in `scripts/`) holding a matrix as data: provider, model, scenarios, with room for an inline `Model.new(...)` where the catalog lacks the model (local Ollama, Z.ai vision). It iterates the matrix, calls `Omni.Verify.run/3`, and prints as the task does. Providers without an API key set are skipped.

- **Targets.** `provider` or `provider/model`; a model outside the matrix runs the defaults. `--only` replaces the selection of every target, so it can run scenarios the matrix leaves out. `--delay ms` sets the pause between scenarios.
- **Gemini's implicit cache** never reported a hit for `gemini-3.8-flash` (same 5.6k-token prefix, up to 60s apart, no `cachedContentTokenCount`), so `cache_usage` is off for Google in the matrix. Gemini has no request-side cache control to verify.
- **Results by day.** `results/YYYY-MM-DD.json` holds `{status, result, time_ms}` per model and scenario, where `result` is the short line. Each run overwrites the cells it ran and keeps the rest, then regenerates `YYYY-MM-DD.md` from it. No provider errors are saved, so results are committed. Nothing is pruned.

Sequential throughout — runs are infrequent, so no concurrency. Models are chosen provider by provider: cheap to mid-range generally, a premium model from Anthropic and OpenAI, more than two for gateways (OpenRouter, OpenCode). The matrix tracks today's common models and shifts over time.

## Capture

No mix task. Each provider has one `capture.exs` script, run with `MIX_ENV=test mix run test/support/fixtures/<provider>/capture.exs`, calling a test-support helper (`Omni.Test.Capture.record`) once per fixture:

- Each call names its output file, so one script records the baseline trio and every shape case for the provider.
- **Existing fixtures are skipped.** Re-recording means deleting the file first, so new cases can be added without re-recording (and paying for) the rest.
- `record` returns the parsed response either way — live, or replayed from the existing fixture through the normal pipeline — so a multi-turn case builds turn 2 from turn 1 exactly as recorded.
- Writes the raw response bytes only. No request fixtures.

## Integration tests

One test module per provider, holding two kinds of test:

- **Baseline** — text, thinking and tool use, recorded from a current cheap model, plus the request target (host, path, auth headers). A model at a moment in time responding the way we expect. Its value is regression protection on each provider's real bytes (usage chunk placement, packed chunks, id formats differ subtly across providers on one dialect), not proof the provider works. Assertions tighten but survive re-recording: stop reason, tool input mentions London, thinking text non-empty, usage present.
- **Shape** — bespoke fixtures for specific quirks, asserting what the fixture exists to show (OpenRouter `reasoning_details` in `private`, Gemini thought signatures on function calls, packed Completions chunks, the Kimi tool-use case, second-turn responses after thinking replay). Sources: quirks known today, and whatever verify finds later — fix, write a case, record, assert.

Baseline helpers are plain functions in a support module (e.g. `Omni.Test.Baseline`: `assert_text/2`, `assert_thinking/2`, `assert_tool_use/2`, `assert_target/4`), called from named tests in each provider file — not a macro generating tests. OpenCode calls them once per dialect. `request_target_test.exs` folds into the provider files.

**Request shape** is tested with assertions, not snapshots: per built-in, capture the outgoing body via a `Req.Test` plug and assert the fields its compat flags control (e.g. Z.ai with `thinking: :high` sends `thinking.type: "enabled"` and `max_tokens`). Dialect unit tests keep covering each flag in isolation.

**Layout:**

```
test/integration/
  <provider>_test.exs              # baseline + shape tests
  loop_test.exs, error_test.exs, structured_output_test.exs, cache_usage_test.exs   # unchanged
test/support/fixtures/
  <provider>/
    capture.exs                    # records everything below
    text.sse  thinking.sse  tool_use.sse
    <shape>.sse ...
  synthetic/                       # hand-written per dialect, unchanged
  files/ → priv/                   # verify assets
```

**Existing fixtures:** new recordings are the default. Where we can't record (NearAI has no key; Groq and Ollama Cloud paid tiers), decide case by case: keep the legacy fixture and accept what it tests, or find a way to record the real one.

## Retired

`test/live/`, `LiveTests`, the `:live` tag and `exclude: [:live]` in `test_helper.exs`, `mix test --include live` in `CLAUDE.md`, `scripts/capture_fixtures.exs`, `scripts/test_loop.exs` (→ `kitchen_sink`), `scripts/test_output.exs` (→ `structured_output`). `Omni.Test.Capture` is rewritten as the capture helper.

## Build order

1. **Verify** — `Omni.Verify` and its scenarios, the mix task, assets in `priv/`. Add to `context/notes/v2-changes.md`.
2. **Sweep** — script and first matrix; run it. Failures feed step 4's shape cases.
3. **Capture and baseline helpers** — rewrite `Omni.Test.Capture`; add `Omni.Test.Baseline`.
4. **Provider by provider** — `capture.exs`, record fixtures, rewrite the test module with baseline and shape tests, add the request shape test. Delete the old fixtures and `request_target_test.exs` as each provider moves.
5. **Retire** the live tests and old scripts; update `CLAUDE.md` (commands, testing layers) and `design.md`.
6. **Contribution path** — document how a provider enters the verified tier (run verify, set compat flags until it passes, write `capture.exs`, add the module, moduledoc and test file) in the `Omni.Provider` tiers section, which defers to it today.

xAI, Mistral and Together then go through the contribution path as its first users.
