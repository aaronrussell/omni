# Providers as data — outline plan

*2026-10-15. Sequences the work described in `providers-as-data.md` (pass one) into phases. Each phase carries its own design pass, so this records what each phase delivers, which open questions it owns, and the decisions that cut across all of them. It does not re-argue the design — read the pass-one note for that.*

## Decisions that hold across every phase

These were settled after pass one and are not reopened inside a phase.

- **Scaffold, then dissolve.** Phase 1 ports every existing provider quirk verbatim into an adapter module under the new behaviour, so all thirteen built-ins work end to end before compat exists. Phase 2 moves that logic into flag-conditional paths in the dialects and retires most adapters. Adapter hooks defined in phase 1 are provisional and documented as such.
- **One merge rule for the overlays.** Values without identity replace, later layer winning. Collections with identity merge shallowly by key, later layer winning per key: `headers` and `compat` by key, `models:` by model id. Keyword lists in config are maps in disguise and are normalised to maps before merging. Phase 1 states the rule once; phase 2 inherits it for `compat` and `like:`.
- **Three tiers, and the table never guesses.** The Builtins table *is* the verified list: every entry has been tested against the live API, with compat set, fixtures recorded, and docs written. A catalog-tier provider gets endpoint, key variable, and dialect from catalog data and speaks that dialect plain, with no quirks; the user sets any flags themselves, including `like:` to borrow a verified set. A custom provider is wholly user-defined. Competitor-inferred flags are not table entries; they are the starting point for a verification PR. `tier` exists to tell the user which promise applies.
- **Documentation is captured, not lost.** Built-in providers lose their modules and with them their moduledocs. The content moves to an extras page. Phase 1 is not done until every deleted moduledoc has a home on that page, however rough; phase 3 makes it good.
- **No side-by-side namespace.** The v2 branch is the isolation. The change reaches `Model`, `Request`, `Dialect` and `Source`, so an `Omni.Next` namespace would duplicate most of the library for no gain.
- **Each phase leaves the branch green.** Tests pass at every phase boundary. The Decisions API second pass builds on phase 1's `dialects` map and may start before phase 4.

Still in force from pass one: flags are named by wire shape, never by provider; flags are provider-level in config, with model-specific variation expressed by adapters or model data; nothing is guessed at load (missing base URL, dialect, or ambiguous key variable is a boot error); configuring is never enabling.

## Phase 1 — Provider struct, loading, config, sources

The structural change. Everything else builds on it.

**Lands**

- `%Omni.Provider{}` as in pass one, minus `compat` (reserved, added in phase 2). Fields: `id`, `name`, `base_url`, `api_key`, `auth`, `headers`, `dialects`, `adapter`, `tier`.
- Three overlays assembled at load: source catalog data, `Omni.Provider.Builtins` table, `config :omni, :providers`. The merge rule above.
- `config :omni, :models` with `providers:`, `source:`, `filter:`; per-provider `models:` in `:providers` config. `:builtins` expands to the table's ids.
- Base URLs include the version segment; dialect paths lose their prefix. Ollama keeps `/api/chat`.
- `auth` as data: `:bearer`, `{:header, name}`, `:none`, `:dialect`. `:dialect` needs a new dialect callback naming the home API's header. This is phase 1 work because OpenCode dissolves here.
- `%Omni.Model{}`: `provider` becomes the embedded struct, `dialect` becomes `dialects` (effective, always filled, copied from the provider when absent). Precedence flips: a provider's declared dialect wins over catalog inference.
- `Omni.Source`: `fetch/2` receives the struct; new `provider/2` callback returns normalised provider-level catalog data. Both built-in sources updated.
- Persistent term layout: one map of provider structs by id, one map of models per provider. `Omni.get_provider/1`. `Omni.Provider.load/1` for runtime additions.
- Adapter behaviour with the four provisional hooks from pass one (`load`, `modify_request`, `modify_body`, `modify_deltas`). Ten built-ins get an adapter holding their current quirk code unchanged; three become pure table entries (Anthropic, Google, OpenAI). OpenCode, Ollama and Ollama Cloud dissolve into struct fields and the precedence flip.
- Error terms for not-loaded versus unknown providers.
- The extras page, seeded with every retired moduledoc.
- Tests: the 32 files referencing providers; integration tests build structs instead of naming modules.

**Design pass owns**

- Whether `Omni.Provider` splits into struct, behaviour, and loading machinery, and the module names if so.
- Exact shape of the source `provider/2` callback, and how a source that has per-model dialect data (llm_db `wire_protocol`) interacts with the precedence flip. Document that a user-declared dialect now suppresses per-model catalog dialects.
- `Model.new/1` and `put_model/2` ergonomics now that a provider struct is required. Probably a form that takes a provider id and resolves the struct.
- Boot-time validation of user config: unknown keys, including v1's `auth_header`, are errors with a migration message.
- Whether the loader logs anything for catalog-tier providers. Current lean: no, `tier` and the docs carry the promise.
- Stale embedded structs after a reload: a documentation sentence, nothing more.
- Final names for error terms and the `tier` field.

**Done when** all thirteen built-ins pass the existing integration tests through the new pipeline, `mix precommit` is green, and the extras page has an entry per retired module.

## Compat research session — before phase 2

A dedicated pass, not a phase. It can run while phase 1 is implemented and must finish before phase 2's design pass. It answers three questions; a survey of flag names alone would leave the structural ones open.

1. **Which flags exist and where libraries converge.** Pi's three compat types (27, 10 and 13 flags), Vercel's `@ai-sdk/openai-compatible`, LiteLLM's provider transformations, OpenRouter's normalisation layer, llm_db's metadata. For each axis, note the consensus shape, where Omni would differ, and whether differing is an improvement. Settle shape-level questions such as specific booleans versus a generic `drop_fields` list.
2. **Where compat lives.** The pass-one options: flat map on the provider; keyed by dialect; effective `compat` on the model mirroring `dialects`, validated per model against its own dialect, with the provider's map as the default. The leaning after pass one is the model-effective shape keyed by capability, because it handles gateways with no special case and aligns with the Decisions API. The research should confirm or overturn that. It also decides whether Groq's per-model effort levels are compat or a model capability fact, by checking how others record per-model reasoning limits.
3. **Whether parse-side variation is flag-driven elsewhere.** The Completions dialect already carries OpenRouter, vLLM, Z.ai and Venice parsing quirks. If these become flags, `handle_event/1` must receive the model or its compat. This also decides whether `modify_deltas` survives.

**Output**: a note, `compat-flags.md`, with the flag table per dialect, the placement decision, the `handle_event` signature, and the list of built-in quirks that remain adapter code after flags. The pass-one seven-flag sketch is superseded by it.

## Phase 2 — Compat flags and the dialect contract

Applies the research. Dialects become the single home for wire-format variation.

**Lands**

- `compat` on the provider struct and in the Builtins table, with `like:` in config.
- `compat_schema/0` on every dialect, validated at load; empty where the research found nothing.
- Dialects read flags at encode time, and at parse time if the research says so. `handle_event` signature changes accordingly.
- Adapters dissolved: each of phase 1's ten adapters either becomes flags or is justified as remaining code. The adapter behaviour is finalised to the hooks that survive.
- Documentation of each flag on the extras page or the dialect moduledocs.

**Design pass owns**

- The final hook set. Pass-one expectation is that `modify_body` and `modify_deltas` may not survive, leaving `load` and `modify_request`. Decide against the actual residue, not in the abstract.
- How adapters that remain express model-specific data: stamping per-model compat in `load`, or model fields.
- Non-completions dialect schemas: what, if anything, Anthropic Messages, Responses, Gemini and Ollama need from day one.
- Whether the warning mechanism from the roadmap is needed here for flags that drop a requested option, such as a provider that ignores `:thinking`.

**Done when** the quirk code in the pass-one audit table is either a flag or an explicitly retained adapter, and no dialect pattern-matches on a provider name.

## Phase 3 — Documentation

Makes the extras page the real reference for built-in providers.

**Lands**

- A providers guide: one section per verified provider carrying what the moduledoc carried today. Alibaba's region table, Groq's effort clamping, Z.ai's structured-output fallback, Ollama's model config, and so on. Generated from the table where that is practical, hand-written where it is not.
- A description of the three tiers and what each promises, including how to borrow a verified compat set and how to contribute a verification.
- `Omni.Provider` moduledoc rewritten for the data model; the top-level `Omni` moduledoc updated.
- `context/design.md` updated so the transient notes can be retired.

**Design pass owns**

- Generated versus hand-written, and whether table entries carry a `notes` field to feed generation.
- Where flag documentation lives: with the dialect or with the provider.

## Phase 4 — Providers on the new model

Uses the machinery. Each verification is small and repeatable.

**Lands**

- A verification procedure: live test, fixture capture, table entry, docs section. The contribution path for the tiers promise.
- Mistral as a verified entry. The catalog has no base URL for it, so the table supplies one.
- Bespoke npm mapping: `@ai-sdk/mistral`, `@ai-sdk/xai`, `@ai-sdk/togetherai` and similar that are OpenAI-compatible in practice. Decide whether this is a table concern or the source's inference table. Resolves the parked OpenCode Mistral item.
- Version-segment fixes for the ten catalog base URLs that lack one, applied as those providers are verified.
- The additional providers the roadmap leaves unnamed.

**Design pass owns**

- Which providers to verify, and in what order.
- Whether a catalog-tier provider that fails at request time with an obviously wrong URL deserves a better error than a 404, which connects to the roadmap's warning mechanism.

## Relationship to other v2 work

- **Decisions API.** Depends on phase 1's `dialects` map. Its compat needs, if any, should be visible to the research session so the placement decision accounts for a second capability. Otherwise independent.
- **Roadmap.** The v2.0.0 section lists providers as data, Mistral, Mistral via OpenCode, and additional providers as separate items. Phases 1 to 3 are the first; phase 4 absorbs the other three.
