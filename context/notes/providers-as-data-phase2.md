# Providers as data — phase 2 implementation plan

*2026-10-16. Step-by-step plan for phase 2 (compat flags, thinking capability data, dialect contract), written after the phase 2 design conversation. Decisions are summarised in the phase 2 section of `providers-as-data-plan.md`; this note carries the detail.*


## Context

Phase 1 of providers-as-data (landed 2026-10-16) made providers data, but every provider quirk was ported verbatim into provider-module callbacks (`modify_body/4`, `modify_deltas/3`) that rewrite whatever the dialect emitted. Phase 2 makes dialects the single home for wire-format variation, as `context/notes/compat-flags.md` sets out:

- **Compat flags.** Per-provider flags, keyed by dialect, which the dialect reads while it encodes.
- **Model thinking capability data.** Per-model facts about what thinking a model accepts. These replace both the per-model clamps and the model-name prefix lists in the dialects.

The modules for Moonshot, Z.ai, Alibaba, NearAI, Venice, OpenRouter and Groq lose most of their quirk code. `modify_deltas` is removed.

### Decisions agreed in conversation (2026-10-16), on top of compat-flags.md

1. **The `%Model{}` field `reasoning` becomes `thinking`.**
   - Type: `false | true | %{optional(:efforts) => [String.t()], optional(:toggle) => true, optional(:budget) => {min | nil, max | nil}}`.
   - `true` means the model reasons but there is no data about how. The catalog's empty `[]` normalises to `true`.
   - Effort values are wire strings (`"none"`, `"minimal"`, `"default"`, …), never atoms.
2. **Effort resolution.**
   - One ladder: `minimal < low < medium < high < xhigh < max`.
   - A requested level is clamped to the model's values: round up to the nearest supported value, else down. "On" never crosses into "off".
   - `"none"` in a model's values only means it can be switched off.
   - `"default"` is sent for any "on" request when it is the model's only "on" value (Groq Qwen).
   - On a model with no effort list, any level just switches thinking on. A budget model gets a budget derived from the level.
   - An explicit `%{budget: n}` is used only on budget models; elsewhere the map's effort applies.
3. **Dynamic thinking lands now, spelled `thinking: true`** ("on, the model decides"):
   - where the API has a native dynamic mode, that mode (Anthropic adaptive with no effort, Gemini 2.5 budget `-1`, Gemini 3 with no level);
   - on toggle-only models, switch on;
   - otherwise, resolve as `:medium`.

   This closes the roadmap item "Dynamic thinking as a first-class level", and `:max` stops meaning "dynamic" on Gemini.
4. **All five dialects use the capability data.** The thinking prefix lists go: Anthropic `@adaptive_prefixes`, Gemini `gemini_3_model?`, Ollama's `gpt-oss` check. Anthropic's `@strict_sampling_prefixes` is unrelated to thinking and stays.
   - Older models need not be perfect: Opus 4.5 and 4.6 may move to budget-style thinking.
   - Gemini 3 levels match by name (`:high` → `"high"`, not today's `"medium"`).
5. **Compat config.**
   - Flat: `compat: [like: :zai, max_tokens_field: "max_tokens"]` applies to the provider's single dialect. A flat list on a provider that speaks several dialects is a boot error that asks for `compat: %{Omni.Dialects.OpenAICompletions => [...]}`.
   - `like:` copies a **built-in's** whole compat map; the layer's own flags overlay it.
   - Layers merge per dialect, then per flag. `omit` and `extra_body` values replace rather than merge.
6. **Hooks.** `config/0`, `models/2`, `modify_request/3` and `modify_body/4` stay and are no longer "provisional". `modify_deltas/3` is removed.
7. **`anthropic-version` stays in `Omni.Providers.Anthropic.config/0`.** Other Anthropic-compatible endpoints ignore it (DeepSeek documents this) and none require it. No new dialect callback.
8. **Live verification.** A `.exs` script Aaron runs with his keys. Built-in compat values and thinking rules are then adjusted from the results.

## Thinking resolution (shared)

New module **`Omni.Dialect.Thinking`** (documented, because custom dialects need it). `resolve(model, opt)` returns one of:

- `nil` — send nothing. This covers three cases: the option is unset; `model.thinking == false`; or off was requested but the model shows no way to switch off (no toggle, no `"none"`, and data is present).
- `:off` — switch off (toggle facet, `"none"` in efforts, or no data).
- `:dynamic` — `thinking: true`. A dialect with no native dynamic form calls `resolve(model, :medium)`.
- `%{effort: String.t() | nil, budget: integer() | nil}` — on.
  - `effort` is clamped to `efforts`, or is the level's own string when there is no data. `:max` → `"xhigh"` stays the no-data fallback for the OpenAI dialects.
  - `budget` is the explicit budget, or a value from the shared table, clamped to the model's `{min, max}`. It is filled only when the model has a budget facet, or has no data.

The shared effort → budget table comes from Anthropic's `effort_to_budget`: low 1024, medium 4096, high 16384, xhigh 24576, max 32768. It replaces Alibaba's and Gemini's tables. Gemini 2.5's budgets change, which is acceptable.

### Per-dialect encoding

| Dialect | Rule |
|---|---|
| **OpenAI Completions** | **Off:** spelled with `thinking_toggle_format` if set, else `"none"` at `thinking_effort_field`.<br>**On, effort list:** the effort at `thinking_effort_field`.<br>**On, no effort list:** the toggle format if set, else today's effort string. A budget also goes to `thinking_budget_field` when that flag is set and the model takes one.<br>**No data and a toggle format set:** use the toggle, which preserves today's Moonshot, Z.ai and Alibaba behaviour.<br>`omit: [:thinking]` sends nothing. |
| **OpenAI Responses** | Effort only (clamped), `"none"` for off when allowed, `summary: "auto"` as today. |
| **Anthropic Messages** | **Efforts and no budget facet:** adaptive (`thinking.type: "adaptive"`, plus `output_config.effort` unless dynamic).<br>**Budget facet, or no data:** `enabled` with `budget_tokens`, adding the budget to `max_tokens` as today.<br>**Off:** `disabled`.<br>`true` on a budget model resolves as `:medium`. |
| **Google Gemini** | **Efforts:** `thinkingLevel` matched by name; dynamic omits the level.<br>**Budget, or no data:** `thinkingBudget`; dynamic is `-1`.<br>**Off:** `thinkingBudget: 0` only when the model can be switched off. |
| **Ollama Chat** | **Efforts:** clamped string.<br>**Toggle, or no data:** boolean. |

## Compat flags — OpenAI Completions

Implemented exactly per the table in `compat-flags.md`:

| Flag | Values |
|---|---|
| `max_tokens_field` | string |
| `thinking_effort_field` | string |
| `thinking_budget_field` | string |
| `thinking_replay_field` | `"reasoning_details"` |
| `thinking_toggle_format` | `:thinking_type`, `:enable_thinking`, `:reasoning_enabled` |
| `output_format` | `:json_object` |
| `attachment_format` | `:file_url` |
| `omit` | `[:cache, :thinking, :strict_schema]` |
| `extra_body` | string-keyed map, merged shallowly into the body |

- Field flags take a dotted path (`"reasoning.effort"`). Add a `put_path/3` helper to `Omni.Util`.
- `thinking_replay_field: "reasoning_content"` (Moonshot) is added only if verification confirms the replay bug.
- `output_format: :json_object` reuses the instruction and system-append code from `Omni.Providers.Zai` and `Omni.Providers.Alibaba`, which is currently duplicated.
- `thinking_replay_field: "reasoning_details"`:
  - **Parse side:** `handle_event/2` emits `{:message, %{private: %{reasoning_details: details}}}`. `StreamingResponse.merge_private/2` already concatenates lists.
  - **Encode side:** reasoning details from the assistant message's `private` go on that message, as OpenRouter's `attach_reasoning_details` does today.
- The other four dialects get `compat_schema/0 → %{}`.

## Built-in compat values

All built-in modules key `compat` by dialect explicitly (`compat: %{Omni.Dialects.OpenAICompletions => [...]}`), so `like:` copies a plain map.

| Module | After phase 2 |
|---|---|
| Moonshot | `thinking_toggle_format: :thinking_type`. `modify_body` deleted. |
| Z.ai | `thinking_toggle_format: :thinking_type`, `output_format: :json_object`, `attachment_format: :file_url`. `modify_body` deleted. |
| Alibaba | `thinking_toggle_format: :enable_thinking`, `thinking_budget_field: "thinking_budget"`, `output_format: :json_object`. `modify_body` deleted. |
| NearAI | `max_tokens_field: "max_tokens"`, `omit: [:cache, :thinking, :strict_schema]`. `modify_body` deleted, along with the dead `store` handling. |
| Venice | `thinking_toggle_format: :reasoning_enabled`. `models/2` (`:pdf`) kept; `modify_body` deleted. |
| OpenRouter | `thinking_effort_field: "reasoning.effort"`, `thinking_replay_field: "reasoning_details"`. Both hooks deleted. |
| Groq | No compat. The clamp is deleted because capability data does it. A small `modify_body` adds `reasoning_format: "parsed"` when a positive effort is sent; today that only happens when clamping, which no longer occurs. Verification decides whether it stays. |

## Implementation steps

Each step ends with `mix precommit` passing. Commit only when Aaron asks.

### Step 0 — Record the plan

- Add the agreed decisions to the phase 2 section of `context/notes/providers-as-data-plan.md`, as the phase 1 section did.
- Save this implementation plan as `context/notes/providers-as-data-phase2.md`.

### Step 1 — `Model.thinking` and the sources

- `lib/omni/model.ex`:
  - field, type, typedoc and moduledoc;
  - `new/1` normalises `%{}` and `[]` to `true` and accepts a keyword list for the map;
  - `new/1` raises a migration message for `reasoning:`. Config `models:` entries go through `new/1`, so they get the message too.
- `lib/omni/source.ex` `build_model/1`: keep `"reasoning"` (boolean) and add `"reasoning_options"`, a list in models.dev form (`effort` / `toggle` / `budget_tokens`). Convert them into the thinking field and update the doc.
- `lib/omni/sources/models_dev.ex`: pass `reasoning_options` through in `model_data/2`.
- `lib/omni/sources/llmdb.ex`:
  - read `extra.reasoning_options`, with **atom or string keys** (the compat-flags side finding);
  - map OpenRouter's `extra.reasoning.supported_efforts` and `mandatory` into the same shape;
  - make `npm_dialect/1` and `reasoning?/1` tolerate string keys too.
- Dialects: replace the `%Model{reasoning: false}` clauses with `thinking: false`. There is no behaviour change yet.
- Tests: `model_test`, `source_test`, both source unit tests, both golden tests (expectations gain `thinking` data), and the dialect tests that build models with `reasoning:`.

### Step 2 — `Omni.Dialect.Thinking` and `thinking: true`

- New `lib/omni/dialect/thinking.ex`: `resolve/2`, the ladder and clamp, and the budget table, with thorough unit tests (`test/omni/dialect/thinking_test.exs`) covering the catalog shapes:
  - Groq Qwen `["none", "default"]`
  - gpt-5-pro `["high"]`
  - Gemini 3.1 image `["minimal", "high"]`
  - toggle + effort
  - toggle + budget
  - budget only
  - no data
- `lib/omni/request.ex` `@schema`: `thinking` accepts `true`.
- Rewrite thinking encoding in all five dialects per the table above. This deletes `@adaptive_prefixes`, `adaptive_model?`, `gemini_3_model?`, `gemini3_level`, `level_to_budget`, the per-dialect `effort_to_budget` and `effort_string` functions, and the Ollama `gpt-oss` check.
- Completions emits plain-home-API thinking here; the providers' `modify_body` still rewrites until step 4.
- Update the dialect tests and `lib/omni.ex`'s `:thinking` option docs (`true`, rounding, budgets).

### Step 3 — The dialect contract and `compat` on the provider

- **`lib/omni/dialect.ex`:**
  - required `compat_schema/0`, a Peri map schema;
  - `handle_event/2` with the signature `(event, Model.t())`;
  - helper `compat(model, dialect)` returning `model.provider.compat[dialect] || %{}`, with a nil provider giving `%{}`;
  - moduledoc and example updated.
- **All five dialects:** `compat_schema/0`. Every `handle_event/1` clause gains the model argument; Gemini's and Responses' delegating clauses pass it through.
- **`lib/omni/request.ex`:** `parse_event/2` calls `dialect.handle_event(event, model)`; the `modify_deltas` branch is removed.
- **`lib/omni/provider.ex`:**
  - a `compat: %{}` field and type;
  - `modify_deltas/3` callback and the `delta` type removed;
  - "Provisional" wording dropped;
  - moduledoc gains `:compat` and `like:`;
  - `config/0` doc lists `:compat`.
- **`lib/omni/provider/loader.ex`:**
  - Add `:compat` to `@config_keys` and `@module_config_keys`.
  - `normalize_value!(:compat)` classifies each layer as flat (atom keys) or keyed (dialect-module keys). Mixed keys raise. `like:` is expanded from `Builtins.module(target).config()[:compat]`; an unknown or non-built-in target raises.
  - Each layer's compat is kept separate until `resolve_dialects/2` has run. Then each layer is resolved to keyed form (a flat layer on a multi-dialect provider raises with the hint) and merged in order: module, then app config and inline options, per dialect, then per flag.
  - `merge_config/2` merges compat per flag only when both sides are the same form; otherwise the later side replaces.
  - `validate_provider!` checks that every compat key is one of the provider's dialects (any capability), and validates each map against `dialect.compat_schema()` with Peri plus an unknown-key check, matching `Request.check_unknown_keys/2`.
  - Boot-error messages name the provider id and the flag.
- **Tests:** a new `describe "compat"` in `test/omni/provider/loader_test.exs` covering flat, keyed, `like:`, layer merge, multi-dialect flat error, unknown flag, unknown `like:` target, and a dialect not on the provider. Also `dialect_test`, `request_test` (delete the `modify_deltas` tests), `provider_test`, and the dialects' `handle_event` tests.

### Step 4 — Completions flags; dissolve the quirk modules

- **`lib/omni/dialects/openai_completions.ex`:**
  - `compat_schema/0` with every flag in the table;
  - flag-conditional encoding (max tokens, thinking spellings, budget, output format, attachment format, `omit`, `extra_body`);
  - `reasoning_details` capture in `handle_event/2` and replay in `encode_message`;
  - provider names removed from the parser comments. The union parse stays.
- **Built-in modules:** `compat` set in `config/0` per the table; `modify_body` and `modify_deltas` deleted as listed. Moduledocs updated: Groq's clamping text, Alibaba's budget text, and the structured-output notes now describe flags and capability data.
- **Tests:**
  - Move the assertions in `test/omni/providers/*_test.exs` that call `modify_body` into flag tests in `test/omni/dialects/openai_completions_test.exs`, one per flag.
  - Provider tests assert each module's `config()[:compat]`, plus a load-level check that the built-in compat validates.
  - Integration tests in `test/integration/{alibaba,zai,nearai,openrouter,moonshot,venice,groq,structured_output}_test.exs` must still pass. They are the behaviour-preservation check for the wire body.

### Step 5 — Docs and notes

- **Moduledocs:**
  - `Omni.Dialects.OpenAICompletions` gets a "Compat flags" section: the table with what each value does on the wire.
  - The other dialects' moduledocs note that they have no flags yet.
  - `Omni.Provider` covers compat and `like:` with an example.
  - `Omni.Model` covers the thinking field.
- **CLAUDE.md:** the "Streaming-first" and "Request building" bullets drop `modify_deltas` and "provisional", and gain compat in one line.
- **`context/notes/v2-changes.md`:** entries for the `reasoning` → `thinking` field, `thinking: true`, effort clamping and budget changes (Gemini 3 by name, Gemini budgets), compat and `like:`, the `compat:` config key, `handle_event/2`, `compat_schema/0`, `modify_deltas` removed, the hooks no longer provisional, and the `Source.build_model/1` `"reasoning_options"` key.
- **`context/notes/providers-as-data-plan.md`:** the phase 2 section becomes "Landed" with the final shape.
- **`context/notes/compat-flags.md`:** an adjustments note covering thinking-data placement, dynamic thinking, keyed built-ins and the `reasoning_content` deferral.
- **`context/roadmap.md`:** dynamic thinking is marked as landed in v2; the phase 2 status is updated.

### Step 6 — Live verification

`scripts/verify_phase2.exs` is run with `mix run scripts/verify_phase2.exs` and not committed. For each case it prints the request body (via `Omni.Request.build/3`), then the outcome of a real `Omni.generate_text/3`: stop reason, thinking length, output tokens, or the error. Cases are skipped when their key variable is missing.

| Provider | Cases |
|---|---|
| Moonshot | `kimi-k3` effort; `kimi-k2.6` toggle; `max_completion_tokens` honoured (small cap → `:length`?); tool loop with thinking on, testing the replay bug |
| Z.ai | `glm-5.3` effort; `glm-4.5` toggle; `max_completion_tokens` honoured |
| Alibaba | `qwen-flash` toggle + budget; `kimi-k3`/`glm-5.2` effort; strict `json_schema` on a model the catalog marks as structured-output, compared with the `json_object` fallback |
| Groq | `gpt-oss-120b` low/high with and without `reasoning_format`; `qwen/qwen3.6-27b` `"default"`; a non-reasoning model with `reasoning_format` |
| Anthropic | `claude-fable-5` adaptive (level and `true`); `claude-haiku-4-5` budget; off |
| Google | `gemini-3-flash-preview` levels by name; off; `gemini-2.5-flash` `true` → `-1` |
| OpenAI (Responses) | `gpt-5-pro` clamp to `"high"`; `gpt-5.2` off; `true` → medium |
| OpenRouter | effort and `reasoning_details` round trip |
| Venice | off via `reasoning.enabled` |
| Ollama Cloud | `gpt-oss:120b` effort string |

Then, from the results:

- Adjust the built-ins' compat. This may add `max_tokens_field` for Moonshot and Z.ai, drop Alibaba's `output_format`, delete Groq's `modify_body`, and add `thinking_replay_field: "reasoning_content"` for Moonshot.
- Adjust the thinking rules.
- Record new fixtures with `Omni.Test.Capture.record/5` where the wire changed.
- Update the notes with the results.

## Verification

- `mix precommit` after each step (compile with warnings as errors, format, tests).
- `test/integration/request_target_test.exs` and the per-provider integration tests confirm hosts, auth and recorded flows still work.
- `mix test --include live` and the step 6 script, run by Aaron with his keys.
- Done when:
  - every quirk in the pass-one audit table is a flag, capability data, or explicitly retained module code (Venice `models/2`, Ollama Cloud `models/2`, and possibly Groq `modify_body`);
  - no dialect pattern-matches on a provider name or a thinking-related model-name prefix.

## Verification results

**Verification closed 2026-10-16.** Changes from it: Z.ai `max_tokens_field`, and Groq's `modify_body/4` retargeted to non-gpt-oss reasoning models. Still unverified live: Z.ai effort models, Groq Qwen, Ollama Cloud effort-list models other than gpt-oss (paid plan), NearAI (wire output unchanged from phase 1). Ollama Cloud generation was verified on 2026-10-19 after a streaming fix (below). The cases are in `scripts/verify_phase2.exs`, kept untracked until those are run.

*Recorded as each provider is run (2026-10-16).*

- **Moonshot.**
  - All cases ok.
  - `kimi-k3` takes `reasoning_effort` (the effort rule is a fix there).
  - With nothing sent, `kimi-k3` still thinks, which is consistent with its data listing no way to switch off.
  - `kimi-k2.6` switches with `thinking.type`.
  - `max_completion_tokens` is honoured (16-token cap → `stop=length`), so no `max_tokens_field` is needed.
  - The `kimi-k3` tool loop with thinking completed 3 steps without `reasoning_content` replay: the suspected replay bug did not reproduce, so `thinking_replay_field: "reasoning_content"` is not added.
  - No compat change.
- **Alibaba.**
  - The thinking cases all passed: `qwen-flash` toggle + budget, off, and dynamic (no budget); `kimi-k3` effort; `glm-5.2` off.
  - `qwen3-next-80b-a3b-thinking` is not served on the international endpoint (404 "Model not exist"), so the budget-only shape is untested live.
  - The `json_object` fallback works.
  - Strict `json_schema` on `qwen3.6-flash` failed with an error about `json_object` requiring "json" in the messages, which suggests Alibaba converts `json_schema` to JSON mode internally.
  - `output_format: :json_object` stays; no compat change.
- **Groq.**
  - `gpt-oss-120b` takes clamped efforts and returns reasoning separately with or without `reasoning_format`.
  - Qwen and Llama were not accessible on a free account (404).
  - Groq's docs: `reasoning_format` is unsupported on gpt-oss, and defaults to `raw` (`<think>` tags in content) on other reasoning models.
  - `modify_body/4` now sends `reasoning_format: "parsed"` to non-gpt-oss reasoning models unless thinking is off — including when `:thinking` is unset, which leaked `<think>` tags before phase 2.
  - Unverified live for Qwen.
- **Anthropic / OpenCode.**
  - All requests accepted: adaptive with effort, adaptive with no effort (`true`), nothing (off), and Haiku 4.5 budget (thinking returned).
  - `claude-fable-5` returned no thinking on a trivial prompt with adaptive thinking (the model chose not to think).
  - On a harder prompt it returned summarized thinking (about 400 chars, 1 block), directly and via Zen.
  - Adaptive thinking works; no change.
- **Google.**
  - All cases ok.
  - Gemini 3 levels by name are accepted (`low`, `high`, no level); `false` (nothing sent) returns no thoughts.
  - Gemini 2.5 `true` (`-1`) and `:max` (24576, clamped) are accepted.
  - No change.
- **OpenAI (Responses).**
  - `gpt-5-pro` accepts `:low` clamped to `"high"`.
  - `gpt-5.2` accepts `"none"` and `true` → `"medium"` (no summary on a trivial prompt).
  - No change.
- **OpenRouter.**
  - `reasoning.effort` is accepted.
  - The `anthropic/claude-sonnet-4.5` tool loop completed 3 steps with `reasoning_details` captured and replayed.
  - No change.
- **Venice.**
  - A model with no data accepts `reasoning: {enabled: true}` and thinks.
  - `deepseek-v3.2` was overloaded (429), so it was retested on `zai-org-glm-4.7-flash`: `reasoning: {enabled: false}` switches off, and `reasoning_effort: "high"` thinks.
  - No change.
- **Z.ai (free `glm-4.7-flash`).**
  - `thinking.type` switches on and off.
  - The `json_object` fallback works.
  - **`max_completion_tokens` is ignored** (a 16-token cap produced 200 tokens) and `max_tokens` is honoured, so Z.ai gains `max_tokens_field: "max_tokens"` (as Pi has it). Retested with the fix: the 16-token cap now stops at 16.
  - `glm-5.3` is not on the free tier.
- **Not testable on current accounts.**
  - **Z.ai effort models** (`glm-5.x`; free tier only). Cloudflare documents its GLM-5.2 `reasoning_effort` mapping as the same as Z.ai's API.
  - **Groq Qwen** (free tier).
  - **NearAI** (no key); **Ollama Cloud** until 2026-10-19.
  - NearAI's wire output is unchanged from phase 1.
  - **Ollama Cloud.**
    - gpt-oss is unchanged, but models whose data lists efforts now get string levels where they got `true`.
    - Ollama's public `https://ollama.com/api/show` (no key) reports each model's `thinking.values`, and they match the catalog: `glm-5.3` and `glm-5.3-flash` `[low, high, max]`; `kimi-k3` and `deepseek-v4.1-flash` `[false, low, high, max]`; `gpt-oss:120b` `[low, medium, high]`; `kimi-k2.6` and `gemma4:31b` `[false, true]`. So the strings sent are values the API declares.
    - `glm-5.2` reports `[false, high, max]` where the catalog has no off switch, so off sends nothing there.
    - `deepseek-v4-flash`, `minimax-m3` and `mistral-large-4` report no thinking values, so their strings are unconfirmed.
    - **2026-10-19, first generation test** (`gpt-oss:120b`, `think: "high"`): failed with `:incomplete_stream`. ollama.com labels its NDJSON stream `content-type: application/json` (local Ollama sends `application/x-ndjson`), so Omni parsed it as SSE and dropped every line. This was a pre-v2 bug: Ollama Cloud streaming had never worked. Fixed in `Request.select_parser/1`, which now reads `application/json` as NDJSON. A curl of the same request showed thinking output and a final `done_reason: "stop"` line.
    - **Retest after the fix, all ok.** `gpt-oss:120b` `:max` → `think: "high"`: 540 chars of thinking, stop. `gemma4:31b` (toggle only): `true` and `:high` both send `think: true` and think; off sends `think: false`, no thinking.
    - `glm-5.3` and `kimi-k3` (effort lists) and `kimi-k2.6` return 402: not on the free plan. String levels on non-gpt-oss models remain unverified live.
