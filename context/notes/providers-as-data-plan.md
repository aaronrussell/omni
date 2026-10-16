# Providers as data — outline plan

*2026-10-15. Sequences the work described in `providers-as-data.md` (pass one) into phases. Each phase carries its own design pass, so this records what each phase delivers, which open questions it owns, and the decisions that cut across all of them. It does not re-argue the design — read the pass-one note for that.*

## Decisions that hold across every phase

These were settled after pass one and are not reopened inside a phase.

- **Scaffold, then dissolve.** Phase 1 ports every existing provider quirk verbatim into provider module callbacks under the new behaviour, so all thirteen built-ins work end to end before compat exists. Phase 2 moves that logic into flag-conditional paths in the dialects and retires most of that code. The request-time hooks defined in phase 1 are provisional and documented as such.
- **One merge rule for the overlays.** Values without identity replace, later layer winning. Collections with identity merge shallowly by key, later layer winning per key: `headers` and `compat` by key, `models:` by model id. Keyword lists in config are maps in disguise and are normalised to maps before merging. Phase 1 states the rule once; phase 2 inherits it for `compat` and `like:`.
- **Three tiers, and the verified list never guesses.** The built-in provider modules (mapped in `Omni.Provider.Builtins`) *are* the verified list: every one has been tested against the live API, with compat set, fixtures recorded, and docs written. A catalog-tier provider gets endpoint, key variable, and dialect from catalog data and speaks that dialect plain, with no quirks; the user sets any flags themselves, including `like:` to borrow a verified set. A custom provider is wholly user-defined. Competitor-inferred flags are not built-in config; they are the starting point for a verification PR. `tier` exists to tell the user which promise applies.
- **Documentation stays with the providers.** *(Revised in phase 1.)* Built-in providers keep their modules, so their moduledocs stay; phase 3 builds a providers guide from them. The extras-page requirement on phase 1 is dropped.
- **No side-by-side namespace.** The v2 branch is the isolation. The change reaches `Model`, `Request`, `Dialect` and `Source`, so an `Omni.Next` namespace would duplicate most of the library for no gain.
- **Each phase logs its user-facing changes** in `v2-changes.md`, the running log that becomes the upgrade guide and changelog entry at release. `CHANGELOG.md` is not touched until then.
- **Each phase leaves the branch green.** Tests pass at every phase boundary. The Decisions API second pass builds on phase 1's `dialects` map and may start before phase 4.

Still in force from pass one: flags are named by wire shape, never by provider; flags are provider-level in config, with model-specific variation expressed by provider module code or model data; nothing is guessed at load (missing base URL, dialect, or ambiguous key variable is a boot error); configuring is never enabling.

## Phase 1 — Provider struct, loading, config, sources

**Landed 2026-10-16** (commits `4ba2d3f`, `c7da6e7`). The design pass changed the shape in several places; this section records what landed, superseding the pass-one note where they differ.

- **One id, no renaming.** A provider's id is its catalog key, snake_cased, and is the only identity: config keys, lookups, catalog lookups. No `catalog_id`, no `provider_id:` source option. Two instances of one provider are not supported; call-site `base_url:`/`api_key:` cover multi-region and multi-key use.
- **Built-ins keep modules; no data table.** `Omni.Provider` is the struct, the module behaviour, and the public API (`get/1`, `load/1`, `builtins/0`, `resolve_auth/1`). `Omni.Provider.Builtins` maps the thirteen built-in ids to modules in `Omni.Providers.*`. A module's `config/0` *is* the verified overlay (pass one's table entry, distributed). Modules carry no id; other providers attach one with `module:` in config. Struct field is `module`, not `adapter`.
- **Struct:** `id, name, base_url, api_key, auth, headers, dialects, module, tier`. `dialects` is `%{text: [Module, ...]}`. `compat` arrives in phase 2.
- **Callbacks, all optional:** `config/0` (keyword overrides), `models/2` (receives models and the merged provider), and the provisional `modify_request/3`, `modify_body/4`, `modify_deltas/3`. Seven built-ins carry quirk code (Alibaba, Groq, Moonshot, NearAI, OpenRouter, Venice, Z.ai); the other six are `config/0` only, plus Ollama Cloud's `models/2` re-stamp.
- **Source:** a single `fetch(id, opts) :: {:ok, provider, models}` returning raw catalog data — a partial provider (name, base URL, single env var as `api_key`, provider-level dialect) and provider-less models with dialects from their own hints. Sources skip models whose own npm package maps to no dialect and models served from another base URL (multi-mount, deferred to phase 4). The npm-to-dialect map stays in the sources; phase 4's bespoke-package mapping belongs there too.
- **Load sequence** (`Omni.Provider.Loader`): resolve module → fetch → merge provider (source ← `config/0` ← app config) and models (source + config `models:` by id) → `models/2` → fill dialect-less models (provider's own first dialect; else the one dialect all models share; else skip) → provider list = own ++ models' → defaults (`auth: :dialect`, name, tier) → validate → stamp → `filter:` → store. **Model data decides a model's dialect**; configured `dialects:` only fills gaps.
- **Validation:** no base URL raises; models with no resolvable dialect raise; no models and no dialect only warns; a missing API key is *not* a boot error (call-site keys are valid). v1 config (per-module keys, the old `:providers` list, modules in `providers:`, `auth_header:`) raises with migration messages.
- **Config:** `:models` selects (`providers:` ids, `source:`, `filter:`); `:providers` configures by id (`name, base_url, api_key, auth, headers, dialects, module, models, source`).
- **Auth as data:** `:bearer | {:header, name} | :none | :dialect`, with `Dialect.auth/0` naming each dialect's home scheme. `:dialect` is the default, which is how OpenCode lost its code. Local Ollama is `:none` (not a verbatim port: set `auth: :bearer` behind a proxy). `anthropic-version` stays in Anthropic's `config/0` until phase 2.
- **Version segment** lives in `base_url`; dialects own resource paths. Ollama keeps `/api/chat`.
- **Model:** `provider` embedded, `dialects: %{text: Module}`; `Model.new/1` takes a struct or a loaded id; `put_model/1`. `put_dialect/3` moves to phase 4 with OpenRouter's extra dialects.
- **Store:** `{Omni, :providers}` and `{Omni, :models, id}`; writes under a lock; reload replaces. One error, `{:unknown_provider, id}`, for unknown and not-loaded.
- **Tests:** `request_target_test.exs` asserts host, path and auth headers for every built-in; `Loader.assemble/2` keeps tests off the shared store.

## Compat research session — before phase 2

A dedicated pass, not a phase. It can run while phase 1 is implemented and must finish before phase 2's design pass. It answers three questions; a survey of flag names alone would leave the structural ones open.

1. **Which flags exist and where libraries converge.** Pi's three compat types (27, 10 and 13 flags), Vercel's `@ai-sdk/openai-compatible`, LiteLLM's provider transformations, OpenRouter's normalisation layer, llm_db's metadata. For each axis, note the consensus shape, where Omni would differ, and whether differing is an improvement. Settle shape-level questions such as specific booleans versus a generic `drop_fields` list.
2. **Where compat lives.** The pass-one options: flat map on the provider; keyed by dialect; effective `compat` on the model mirroring `dialects`, validated per model against its own dialect, with the provider's map as the default. The leaning after pass one is the model-effective shape keyed by capability, because it handles gateways with no special case and aligns with the Decisions API. The research should confirm or overturn that. It also decides whether Groq's per-model effort levels are compat or a model capability fact, by checking how others record per-model reasoning limits.
3. **Whether parse-side variation is flag-driven elsewhere.** The Completions dialect already carries OpenRouter, vLLM, Z.ai and Venice parsing quirks. If these become flags, `handle_event/1` must receive the model or its compat. This also decides whether `modify_deltas` survives.

**Output**: a note, `compat-flags.md`, with the flag table per dialect, the placement decision, the `handle_event` signature, and the list of built-in quirks that remain adapter code after flags. The pass-one seven-flag sketch is superseded by it.

## Phase 2 — Compat flags and the dialect contract

Applies the research. Dialects become the single home for wire-format variation.

**Lands**

- `compat` on the provider struct and in built-in modules' `config/0`, with `like:` in config.
- `compat_schema/0` on every dialect, validated at load; empty where the research found nothing.
- Dialects read flags at encode time, and at parse time if the research says so. `handle_event` signature changes accordingly.
- Quirk code dissolved: each of phase 1's seven quirk modules either becomes flags or is justified as remaining code. The provider module behaviour is finalised to the hooks that survive.
- Documentation of each flag in the dialect moduledocs or the providers guide.

**Design pass owns**

- The final hook set. Pass-one expectation is that `modify_body` and `modify_deltas` may not survive, leaving `load` and `modify_request`. Decide against the actual residue, not in the abstract.
- How remaining module code expresses model-specific data: model capability fields (see `compat-flags.md`), set in `models/2` or by sources.
- Non-completions dialect schemas: what, if anything, Anthropic Messages, Responses, Gemini and Ollama need from day one.
- Whether the warning mechanism from the roadmap is needed here for flags that drop a requested option, such as a provider that ignores `:thinking`.

**Done when** the quirk code in the pass-one audit table is either a flag or explicitly retained module code, and no dialect pattern-matches on a provider name.

**Landed 2026-10-16.** Live verification closed the same day; results and the remaining unverified items are in `providers-as-data-phase2.md`. It added `max_tokens_field: "max_tokens"` to Z.ai and retargeted Groq's `modify_body/4`.

**Design pass outcome (2026-10-16).** Implementation plan in `providers-as-data-phase2.md`. Decided on top of `compat-flags.md`:

- **`%Model{}` `reasoning` becomes `thinking`**: `false | true | %{efforts, toggle, budget}`. `true` means reasoning with no data. Effort values are wire strings.
- **Effort resolution** is shared (`Omni.Dialect.Thinking`): ladder `minimal < low < medium < high < xhigh < max`, round up then down, never across on/off; `"none"` marks off-able; `"default"` stands in for any "on" when it is the only on value. Levels give budgets via one shared table, clamped to the model's range.
- **Dynamic thinking lands as `thinking: true`**: the API's native dynamic mode where one exists, switch on for toggle-only models, else `:medium`. Closes the roadmap item.
- **All five dialects** use the capability data; thinking-related model-name prefix lists go. Older models (Opus 4.5/4.6) need not be perfect; Gemini 3 levels match by name.
- **Compat config**: flat keyword applies to the provider's single dialect (error on a multi-dialect provider, which must key by dialect module); `like:` copies a built-in's whole compat; merge per dialect then per flag. Built-in modules key compat by dialect explicitly.
- **Hooks**: `config/0`, `models/2`, `modify_request/3`, `modify_body/4` stay and lose "provisional"; `modify_deltas/3` goes.
- **`anthropic-version`** stays in the Anthropic module: other Anthropic-compatible endpoints ignore it and none require it. No dialect header callback.
- **Live verification** by a script Aaron runs; built-in compat is adjusted from the results.

What landed, beyond the decisions above: `compat` merges as stacked layers (module `config/0`, app config, inline opts) resolved once dialects are derived; flat flags with an empty set (e.g. `like:` alone) are fine on multi-dialect providers. The `_format` enums include the home value (`output_format: :json_schema`, `attachment_format: :file`) so a borrowed flag can be reset. `thinking_replay_field` ships with `"reasoning_details"` only. Residual module code: Venice `models/2`, Ollama Cloud `models/2`, Groq `modify_body/4` (`reasoning_format: "parsed"` for reasoning models other than gpt-oss, unless thinking is off).

## Phase 3 — Documentation

Builds the real reference for built-in providers from their moduledocs.

**Lands**

- A providers guide: one section per verified provider carrying what the moduledoc carried today. Alibaba's region table, Groq's effort clamping, Z.ai's structured-output fallback, Ollama's model config, and so on. Generated from module docs and `config/0` where that is practical, hand-written where it is not.
- A description of the three tiers and what each promises, including how to borrow a verified compat set and how to contribute a verification.
- `Omni.Provider` moduledoc rewritten for the data model; the top-level `Omni` moduledoc updated.
- `context/design.md` updated so the transient notes can be retired.

**Design pass owns**

- Generated versus hand-written: a guide assembled from module docs and `config/0` values, or written by hand.
- Where flag documentation lives: with the dialect or with the provider.

## Phase 4 — Providers on the new model

Uses the machinery. Each verification is small and repeatable.

**Lands**

- A verification procedure: live test, fixture capture, built-in module, docs section. The contribution path for the tiers promise.
- Mistral as a verified built-in. The catalog has no base URL for it, so its module's `config/0` supplies one.
- Bespoke npm mapping: `@ai-sdk/mistral`, `@ai-sdk/xai`, `@ai-sdk/togetherai` and similar that are OpenAI-compatible in practice, added to the sources' npm-to-dialect tables (decided in phase 1). Resolves the parked OpenCode Mistral item.
- Version-segment fixes for the ten catalog base URLs that lack one, applied as those providers are verified.
- The additional providers the roadmap leaves unnamed.

**Design pass owns**

- Which providers to verify, and in what order.
- Whether a catalog-tier provider that fails at request time with an obviously wrong URL deserves a better error than a 404, which connects to the roadmap's warning mechanism.

## Relationship to other v2 work

- **Decisions API.** Depends on phase 1's `dialects` map. Its compat needs, if any, should be visible to the research session so the placement decision accounts for a second capability. Otherwise independent.
- **Roadmap.** The v2.0.0 section lists providers as data, Mistral, Mistral via OpenCode, and additional providers as separate items. Phases 1 to 3 are the first; phase 4 absorbs the other three.
