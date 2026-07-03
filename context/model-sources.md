# Model Sources Design Document

**Status:** Approved — Phases 1 (dialect precedence flip), 2 (source behaviour, config reshape, ModelsDev source), 3 (LLMDB source), and 4 (ModelsDev live mode) complete
**Last updated:** July 2026

> **Phase 2 deviation:** the snapshot capture became a *new* task, `mix omni.snapshot`, instead of rewriting `mix models.update`. Both legacy tasks (`models.update`, `models.update_llmdb`) remain in the tree untouched and unused at runtime, to be deleted in a later cleanup — this shifts Phase 3's "delete `models.update_llmdb`" step into that cleanup and Phase 5's task-description wording accordingly. Phase 2's validation diff came back exact: old transform and ModelsDev source produce identical model sets for all 12 built-ins over the same snapshot.
>
> **Phase 2 amendment (memoization):** the doc's original suggestion to memoize the decoded snapshot in `:persistent_term` was replaced post-review — ~9 MB of decoded terms needed only at load time would have lived for the VM's lifetime. Instead, `Omni.Source` provides a pass-scoped cache: `Omni.Provider.load/1` wraps each load pass in `Omni.Source.with_cache/1`, sources memoize shared work via `Omni.Source.memo/2` (process dictionary), and the scope teardown garbage-collects the calling process. One decode per pass, zero-copy reads, nothing resident post-boot; a standalone `load_models/2` call outside a pass simply decodes fresh (~36 ms). The `fetch/2` behaviour contract is unchanged; lifecycle callbacks (setup/teardown) were considered and rejected — any pass-scoped state must be ambient because the call chain between fetches runs through the fixed zero-arity `models/0`.
>
> **Phase 3 notes:** the dialect cascade shipped as approved (wire_protocol → npm → fallbacks), with two settled details. First, the OpenCode gateway-fallback question: **needed** — a `@gateway_fallback %{opencode: "openai_completions"}` map covers the ~20 OpenCode models carrying neither npm nor wire metadata (mirroring models.dev's provider-level `@ai-sdk/openai-compatible`); OpenCode models have no `wire_protocol` at all, so npm and this map do all the work there. Second, the no-dialect policy: the source emits `nil` when no catalog signal resolves, `Provider.build_model/2` falls back to `module.dialect()`, and if that is also nil the builder's raise is caught by the source's per-model rescue → warn + skip (a module-first alternative was considered and rejected — catalog data stays the source of truth; the module dialect is strictly a fallback, consistent with the Phase 1 flip). Consequence, accepted as an upstream data issue: the 11 OpenAI models with mislabeled `wire_protocol` (the codex issue below) load as `openai_completions` until fixed upstream — the validation diff shows exactly those 11 dialect mismatches vs the ModelsDev source and none elsewhere; remaining id-set deltas are snapshot freshness. The unknown-wire dead ends in the prototype now fall through to the module fallback instead (recovers 4 models). The LLMDB source skips `Omni.Source.memo/2` — llm_db keeps its catalog in its own `:persistent_term` store. The compile-without-llm_db gate is an env-gated dep (`OMNI_SKIP_LLMDB=1` in mix.exs) plus a dedicated CI job running the full suite; llm_db-dependent test modules are wrapped in `if Code.ensure_loaded?(LLMDB)`. Per the Phase 2 deviation, `mix models.update_llmdb` and `priv/models-llmdb/` remain in-tree for the later cleanup.
>
> **Post-Phase-4 config revision:** the config shape below was renamed before release (design session 2026-07-03). The top-level key is `:models`, not `:providers` — the config primarily answers "which models, from where", and the rename makes legacy detection trivial (any `config :omni, :providers` raises with a migration message, no shape-sniffing). The `load:` key became `providers:` (the `providers: providers` collision that motivated `load:` disappeared with the rename). The `:models_dev`/`:llm_db` shorthand atoms were dropped entirely: sources are configured by full module (`module | {module, opts}`), matching how the wider ecosystem configures pluggable backends and not privileging built-in sources over custom ones. The normative sections below are updated; the phased plan retains the original names as a historical record of what each phase shipped.
>
> **Phase 4 notes:** the `fetch_timeout:` opt was dropped — the request budget is hard-coded (~5s total: 2s connect + 3s receive, `retry: false` since Req's default 3× retries would blow it) on the grounds that fetch failure is soft via the resilience ladder; the `{module, opts}` form leaves room to add a knob later without a contract change. `cache_ttl:` is **milliseconds** (default `to_timeout(hour: 24)`; `0` means always fetch), not the seconds the original sketch implied. The default `cache_dir:` is a per-user directory under `System.tmp_dir!()` (`omni_<user>` — the suffix avoids shared-`/tmp` ownership collisions between users on Linux). Cache writes are best-effort (temp-then-rename in the target dir for atomicity; a write failure warns and the fetched data serves that boot in-memory) and a corrupt cache file is treated as missing (warned, then healed by the next successful fetch). The fetched body is validated as decodable JSON before it is cached. Live opts are part of the source's memo key, so providers sharing identical live config share one fetch per load pass while per-module overrides fetch separately. Tests inject HTTP via an undocumented `plug:` opt on the source (anonymous function plugs), mirroring the request pipeline's seam.

---

## Overview

Omni currently ships its model catalog as curated per-provider JSON files in `priv/models/`, generated at development time by `mix models.update` from the models.dev API. This design replaces that arrangement with **pluggable model sources**: a behaviour that answers "give me the models for this provider", resolved from configuration at load time.

Omni becomes model-source agnostic. It ships two source implementations and users can write their own:

- **`Omni.Sources.ModelsDev`** (default) — reads a verbatim models.dev snapshot bundled in the package, transforming it into `%Omni.Model{}` structs at load time. Optionally fetches live data from models.dev instead of using the snapshot.
- **`Omni.Sources.LLMDB`** — sources the catalog from the optional [`llm_db`](https://github.com/agentjido/llm_db) hex package, for users already in that ecosystem or who prefer its curation.

Both sources have the same shape: *a snapshot shipped in a package + a load-time transform + an optional freshness mechanism* (ModelsDev's `live:` mode; llm_db's own `sources:` config). The checked-in data becomes a snapshot artifact rather than a curated format Omni owns.

### Goals

- Users can swap the model data source globally, per provider, or per call site.
- Model data freshness becomes an opt-in knob instead of a release-cadence problem.
- Custom providers get catalog data without hand-writing model lists.
- Omni stops owning a curated JSON schema; `mix models.update` becomes a dumb snapshot capture.

### Non-goals

- **Not replacing `%Omni.Model{}`.** Sources produce Omni's struct; the runtime model store (`:persistent_term`, keyed `{Omni, provider_id}`) is unchanged.
- **`llm_db` stays optional.** Omni works fully without it; `{:llm_db, "~> 2026.6", optional: true}` is already in mix.exs.
- **No filter DSL in Omni.** Model filtering is delegated to each source's own mechanisms (llm_db's `allow`/`deny` config; models.dev filtering may come later as source opts). Provider-level restriction stays in `config :omni, :models`.

---

## Architecture

### The `Omni.Source` behaviour

```elixir
defmodule Omni.Source do
  @callback fetch(provider :: module(), opts :: keyword()) ::
              {:ok, [Omni.Model.t()]} | {:error, term()}
end
```

A single thin callback. `opts` is the source's config opts merged with the call-site opts (call-site wins). The recognized error `{:error, :unknown_provider}` means "this provider isn't in my catalog"; any other error term is also legal.

**Struct contract — sources return ready-to-use models.** The behaviour returns `[%Omni.Model{}]`, not intermediate maps. This keeps the system's interchange type singular (`models/0` already returns structs) and avoids enshrining any serialization format as public API. The contract invariants, which the behaviour's `@moduledoc` must spell out:

- `id` — present, the provider's model identifier string
- `provider` — the module passed to `fetch/2`
- `dialect` — a resolved dialect **module, never `nil`**. Beware: `Omni.Model` has `@enforce_keys [:dialect]`, but that only rejects an *omitted* key — `Model.new(dialect: nil)` builds silently. Dialect resolution is each source's responsibility; a model whose dialect cannot be resolved must be skipped (with a warning) or raise, per the source's error policy.

To avoid duplicating construction logic, the current private `Provider.build_model/2` becomes a **public shared helper** that builds a struct from a data map + provider module, implementing the dialect precedence (data wins → `module.dialect()` fallback → raise), date parsing, and field defaults. Both shipped sources use it internally; custom sources may.

**Error policy — resilient boot.** Both shipped sources skip individual bad models with a `Logger.warning` and log a per-provider summary (N loaded, M skipped). Boot never crashes on one bad catalog entry. (An earlier draft had the bundled source raise instead, on the theory that shipped data is human-reviewed; with verbatim snapshots there is no reviewed artifact, so the CI golden test guards the shipped snapshot + transform combination instead — see [Quality gates](#quality-gates-and-testing).)

### `load_models/2` — the single entry point

`Omni.Provider.load_models(module, opts \\ [])` replaces the current `load_models(module, file)`. It resolves the source, calls `fetch/2`, and applies the failure policy:

```elixir
def models do
  Omni.Provider.load_models(__MODULE__)                      # built-ins
end

def models do
  Omni.Provider.load_models(__MODULE__, provider_id: :acme)  # custom provider
end
```

Recognized opts: `:source` (a source override, see resolution below) and `:provider_id` (the caller's identity in the source's catalog). All opts are passed through to `fetch/2`, so sources can define their own call-site opts.

**Why here and not `Provider.load/1`:** `models/0` must remain the single authority for a provider's models. Real provider logic lives there today — Ollama's config-models branch (hand-configured local models beat any catalog), Venice's `:pdf` modality enrichment, and (post-flip) Ollama's native-dialect preference. Intercepting at `load/1` would bypass all of it. `load_models/2` sits *inside* `models/0`, so provider-specific logic wins by construction.

The old binary second argument gets a deprecation clause that raises with a migration message (`load_models(module, file) when is_binary(file)`), since the curated files it pointed at no longer exist.

### Source resolution

Resolved per `load_models/2` call, in priority order:

1. **Per-module app config** — `config :omni, Omni.Providers.OpenAI, source: ...` (app user, provider-specific)
2. **Call-site opt** — `load_models(__MODULE__, source: ...)` (provider author's default)
3. **Global config** — `config :omni, :models, source: ...` (app user, general)
4. **Default** — `Omni.Sources.ModelsDev`

The ladder reads: the user's provider-specific intent trumps everything; the author's call-site value is that provider's default, beating the user's general setting but never their specific one. Note the deliberate asymmetry with the `api_key` three-tier merge (where call-site wins): there the call site is end-user code at request time; here it is provider-author code, so user config must be able to override it. Built-ins pass no call-site source, collapsing the ladder to the intuitive per-module → global → default.

Source values are `module | {module, opts}`, normalized internally to `{module, opts}` (the shorthand atoms were dropped post-Phase-4 — see the config revision note above). The `{module, opts}` form is supported from day one so adding options is never a contract change.

**No cross-source fallback.** If the resolved source returns an error for a provider, `load_models/2` logs a warning and returns `[]`. Models never silently load from a source the user didn't configure. The warning must be actionable: name the source, the provider id tried, and the remediation (pass `provider_id:`, or pin this provider's source via per-module config). A source returning `{:ok, []}` (provider known, filtered to nothing) is not a warning — that's user filtering doing its job.

Within-source resilience is a different thing and is expected: ModelsDev's live mode falling back from live fetch → cache → bundled snapshot is the same source serving the same data at different freshness, and is part of that source's own contract.

### Provider identity — the two-id problem

A provider has an Omni id (`:moonshot`) and possibly a different id in a source's catalog (`"moonshotai"` in models.dev, `:moonshotai` in llm_db). Handling:

- **Built-ins:** `fetch/2` receives the provider module; the source reverse-looks-it-up in `Omni.Provider.builtin_providers/0` to get the Omni id, then applies its own internal rename map. Renames live *inside each source* — call sites never see them. (Module-name munging is not viable: `Macro.underscore` gives `open_ai`/`near_ai`/`open_code` where catalogs say `openai`/`nearai`/`opencode`.)
- **Custom providers:** must pass `provider_id:` — it is used verbatim as the catalog id by the active source. A custom module cannot infer its own Omni id (`{Omni, :provider_ids}` is written *after* `models/0` runs during `load/1`), and doesn't need to.

Each source consumes the opts it understands, so one custom-provider line works under any source: the ModelsDev source and the LLMDB source both read `provider_id:`; a hypothetical file-based source would read its own opt.

---

## Configuration

### New `:models` config (breaking change)

```elixir
config :omni, :models,
  source: Omni.Sources.ModelsDev,           # module | {module, opts} — default Omni.Sources.ModelsDev
  providers: [:anthropic, :openai,          # which providers to load — default :all
              acme: MyApp.Providers.Acme]   # {id, module} pairs register custom providers
```

- `providers:` carries the semantics of the legacy provider list: bare atoms name built-ins (unknown atoms raise), `{id, module}` pairs register custom providers, `:all` (the default) loads every built-in.
- The legacy key (`config :omni, :providers`, any value) **raises at boot with a migration message** — a hard break, deliberately loud rather than silently misread. A malformed value under `:models` raises the same message.
- `Omni.Provider.load/1` (the documented runtime-loading API) is unchanged: it takes a plain provider list; source resolution happens inside `load_models/2`.

### Per-provider override

```elixir
# "llm_db everywhere, except keep openai on the bundled snapshot"
config :omni, :models, source: Omni.Sources.LLMDB
config :omni, Omni.Providers.OpenAI, source: Omni.Sources.ModelsDev
```

Uses the existing per-provider-module config convention (same place as `api_key`, `base_url`, Ollama's `models:`). This is the escape hatch for "the alternative source has bad data for one provider" — and the remediation when a global source flip empties a custom provider that the source doesn't know.

### What Omni does *not* configure

Filtering and freshness for the LLMDB source belong to llm_db's own config, documented with pointers rather than wrapped:

```elixir
config :llm_db,
  allow: %{anthropic: ["claude-*"]},                # glob allow/deny filtering
  deny: %{openai: ["*codex*"]},
  sources: [{LLMDB.Sources.ModelsDev, %{}}]         # llm_db's own live-refresh mechanism
```

---

## Source: `Omni.Sources.ModelsDev` (default)

### Snapshot capture — `mix models.update`

The task becomes a dumb capture: `GET https://models.dev/api.json`, write the response **verbatim** to `priv/models/models_dev.json`. One file, all providers, no transformation, no filtering. The per-provider curated files (`priv/models/*.json`) are deleted.

Keep the snapshot **unpruned** (all ~60+ models.dev providers, not just Omni's built-ins, ~1–2 MB plain JSON). This enables the emergent capability below and keeps data updates fully decoupled from transform-code changes. Plain JSON, not gzipped — git compresses objects and the hex tarball is compressed; revisit only if size becomes a problem.

### Load-time transform

The logic currently in `Mix.Tasks.Models.Update` relocates into the source, applied per `fetch/2` call:

- **Eligibility:** reject `status == "deprecated"`; require `tool_call == true`; require text in input and output modalities.
- **Dialect:** the `@npm_to_dialect` map (npm package name → dialect string), reading the per-model npm override before the provider-level npm (`model["provider"]["npm"] || provider_data["npm"]`); unresolved → the shared builder falls back to `module.dialect()`; still unresolved → skip + warn.
- **Modalities** filtered to Omni-supported; costs/limits defaulted to 0; fields mapped as today.
- **Renames** (Omni id → models.dev catalog key): `:moonshot → "moonshotai"`, `:ollama → "ollama-cloud"`.
- Provider key missing from snapshot → `{:error, :unknown_provider}`.

**Memoization:** `Provider.load/1` calls `models/0` per provider, so the source must parse the snapshot once per boot and memoize the decoded payload (e.g. `:persistent_term` under a source-private key), not re-parse a 1–2 MB file twelve times. The parsed payload lingering in memory post-boot is an acceptable cost; freeing it is a possible later optimization.

### Emergent capability: catalogs for custom providers

Because the snapshot is verbatim and unpruned, a custom provider can point at *any* models.dev catalog — including providers Omni ships no module for:

```elixir
defmodule MyApp.Providers.Mistral do
  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config, do: %{base_url: "https://api.mistral.ai", api_key: {:system, "MISTRAL_API_KEY"}}

  @impl true
  def models, do: Omni.Provider.load_models(__MODULE__, provider_id: :mistral)
end
```

"Add a provider" collapses to a module with `config/0` and a catalog id. This replaces the old pattern of custom providers shipping their own curated JSON file (the multi-dialect gateway example in the `Omni.Provider` moduledoc needs rewriting accordingly). Hand-specified models remain available by building structs directly in `models/0` (see Ollama's config branch and the moduledoc example).

### Live mode (Phase 4)

```elixir
config :omni, :models,
  source: {Omni.Sources.ModelsDev, live: true, cache_ttl: to_timeout(hour: 12)}
```

Opts: `live:` (default `false`), `cache_dir:` (default a per-user directory under `System.tmp_dir!()` — never priv, which is read-only in releases), `cache_ttl:` (milliseconds, default 24h). The fetch's request budget is fixed at ~5s and not configurable (see Phase 4 notes).

Resilience ladder, warning at each degradation step:

1. Cache fresh (< TTL) → use it, no network.
2. Cache stale/missing → fetch from models.dev → success: write cache (write-temp-then-rename), use it.
3. Fetch fails → use stale cache with a warning (the user asked for *fresher* data, not *different* data — stale beats empty).
4. No cache at all → bundled snapshot with a warning.

The fetch runs inside `Application.start` of `:omni` and blocks the host app's supervision tree, hence the tight fixed timeout. Synchronous-with-timeout is the V1 design; boot-from-snapshot + background refresh + atomic `:persistent_term` swap (as llm_db does with epochs) is the obvious V2 if boot latency matters. Document the opt-in network egress at boot for enterprise users.

---

## Source: `Omni.Sources.LLMDB`

### Optional-dependency mechanics

- `Code.ensure_loaded?(LLMDB)` guard; if the source is selected but the package is absent, **raise at boot** with a clear "add `{:llm_db, ...}` to your deps" message — configured-but-missing is a config error, not a data error.
- `@compile {:no_warn_undefined, [LLMDB, LLMDB.Model]}` so Omni compiles without it.
- `Application.ensure_all_started(:llm_db)` before reading (belt-and-braces; as an optional dep, OTP starts it before `:omni` when present, and its own `Application.start` loads its snapshot).

### Transform

The reference implementation is the shelved prototype `Mix.Tasks.Models.UpdateLlmdb`, validated by diffing its output against the models.dev pipeline. The transform relocates into the source; the prototype task is then deleted. Gotchas that MUST carry over:

- **Reasoning:** `capabilities.reasoning.enabled` is unreliable upstream (a materialized schema default, wrong on ~10 models). OR it with: `extra[:reasoning][:mandatory] == true`, non-empty `extra[:reasoning][:supported_efforts]`, non-empty `extra[:reasoning_options]`. **Use non-empty list checks, never truthiness** — `[]` is truthy in Elixir and caused 11 false positives.
- **`extra` is atom-keyed at runtime** and is llm_db's unmapped models.dev passthrough — fragile across llm_db versions. Wrap per-model transforms in `rescue` → log + skip.
- **Dialect cascade:** `execution.text.wire_protocol` (map `openai_chat → openai_completions`, `google_generate_content → google_gemini`) → `extra[:provider][:npm]` via the npm map → emit `nil` and let the shared builder fall back to `module.dialect()` → still unresolved: skip + warn. For multi-dialect OpenCode (`dialect/0` is `nil`), the cascade must resolve per-model; re-run the prototype diff during implementation to check whether any OpenCode models relied on its hardcoded `openai_completions` fallback before deciding if a small gateway-fallback map is needed.
- **Eligibility:** `capabilities.chat == true`, `capabilities.tools.enabled == true`, not `LLMDB.Model.retired?/1` (date-aware), text in input+output modalities. (Slight divergence from the ModelsDev filter, which rejects *deprecated*; both match their respective validated prototypes. Aligning on deprecated-or-retired is a separate future decision — it prunes ~29 models.)
- **Aliases:** llm_db returns canonical records with an `aliases` list, and Omni's friendly ids are often the aliases. Expand one entry per alias (id swapped), dedupe by id, canonical wins.
- **Costs:** clamp negatives with `max(0, x)` — OpenRouter router models carry a `-1.0e6` sentinel. Missing → 0.
- **Renames** (Omni id → llm_db provider id): `:moonshot → :moonshotai`, `:ollama → :ollama_cloud`.
- **Unknown provider:** `LLMDB.provider(id)` → `{:error, :not_found}` → return `{:error, :unknown_provider}`. Note llm_db cannot distinguish "never heard of it" from "user denied it via `config :llm_db, deny:`" (filtering is baked into its snapshot at load). Under the no-fallback policy both produce warn + empty, which is correct either way.

### Known upstream data issues

Worth reporting to the llm_db author (in contact; exact model lists reproducible from the comparison work) — non-blocking side task:

- `capabilities.reasoning.enabled` materialized-default bug (openrouter Claudes, gemini-2.5-flash-lite, gpt-5.x-chat).
- `wire_protocol: openai_chat` on Responses-only codex models (`gpt-5.3-codex`, `gpt-5.4*`, `gpt-5.5*`).

---

## Prerequisite: dialect precedence flip

`Provider.build_model/2` currently does `module.dialect() || Dialect.get!(data["dialect"])`. Flip it so data wins:

```elixir
dialect =
  case data["dialect"] do
    nil -> module.dialect() || Omni.Dialect.get!(nil)   # raises a clear message
    name -> Omni.Dialect.get!(name)                      # raises on unknown string
  end
```

The noisy failure must stay in dialect resolution (not delegated to the struct) because `Model.new(dialect: nil)` builds silently despite `@enforce_keys`.

**Ollama override:** Ollama has two APIs; catalog data says `openai_completions` (models.dev's view) but Omni deliberately prefers the native API (`OllamaChat` + NDJSON). After the flip, Ollama's `models/0` re-applies its preference over whatever any source returned:

```elixir
def models do
  case Application.get_env(:omni, __MODULE__, [])[:models] do
    nil -> Omni.Provider.load_models(__MODULE__) |> Enum.map(&%{&1 | dialect: dialect()})
    model_ids -> Enum.map(model_ids, &build_model/1)
  end
end
```

This is the concrete illustration of why `models/0` stays authoritative over every source.

Also update the two moduledocs documenting the old precedence: `Provider.load_models/2` and `Mix.Tasks.Models.Update`, plus the "Multi-dialect providers" section of the `Omni.Provider` moduledoc.

---

## Quality gates and testing

The current quality gate — a human reviewing the diff of regenerated curated JSON — disappears with verbatim snapshots (nobody ever reviews transformed output). Its replacement:

- **CI golden test:** run the ModelsDev transform over the bundled snapshot and assert invariants — every model has a resolved dialect module, every built-in provider yields a non-empty model list within expected count ranges, and a handful of golden models match exactly (id, dialect, costs, context size). Runs offline on every commit; guards the shipped snapshot + transform combination.
- **Source unit tests:** transform edge cases per source (dialect cascade, reasoning workaround, alias expansion, cost clamps, skip-and-warn paths).
- **Resolution tests:** the source ladder (per-module → call-site → global → default), legacy-config raise, warn-and-empty on source error. A stub source implementing the behaviour makes these trivial — a side benefit of the behaviour design.
- **LLMDB tests** run in dev/test where `llm_db` is present. A CI job compiling Omni *without* llm_db (or an equivalent check) guards the optional-dep mechanics.
- **Live-mode tests** stub HTTP via `Req.Test` (cache hit/miss/stale, fetch failure ladder).

Dev-time validation for Phase 2: compare the new pipeline's loaded model set against the current curated files once, before deleting them.

---

## Breaking changes and migration

| Change | Migration |
| --- | --- |
| `config :omni, :providers` → `config :omni, :models` keyword shape | Move the list under `providers:`; the legacy key raises with instructions |
| `load_models(module, file)` → `load_models(module, opts)` | Built-ins updated in-repo; custom providers with own JSON switch to `provider_id:` or build structs in `models/0` |
| Curated `priv/models/*.json` schema removed | No user-facing contract existed on the files themselves; custom-file pattern replaced per above |
| `mix models.update` output format | Maintainer-only task; snapshot committed as before |

Dialect precedence flips from provider-wins to data-wins, but bundled data and provider declarations agree for every built-in (zero null dialects across all files; Ollama re-applies its preference), so no observable behavior change.

Version: undecided — an earlier draft suggested 2.0.0, but Aaron is currently leaning **1.6** (final call at release time; nothing in code or docs should presume 2.0).

---

## Phased project plan

Each phase is a self-contained, shippable unit intended to be workable as an independent session, in order. This document is the guiding resource; update its status header as phases land.

### Phase 1 — Dialect precedence flip

Small standalone prerequisite. No behavior change for built-ins.

- Flip precedence in `Provider.build_model/2` (data `"dialect"` wins → `module.dialect()` fallback → clear raise; raise stays in dialect resolution, not the struct).
- Ollama `models/0` re-applies `dialect()` over loaded models in the catalog branch.
- Update moduledocs: `Provider.load_models/2`, `Mix.Tasks.Models.Update`, `Omni.Provider` "Multi-dialect providers" section.
- Unit tests for the new precedence; assert every loaded Ollama model has `OllamaChat`.

**Done when:** `mix test` green; loaded model set identical to before.

### Phase 2 — Source behaviour, config reshape, ModelsDev source

The structural core; largest phase.

- `Omni.Source` behaviour (contract + invariants documented in `@moduledoc`, marked experimental).
- Make the struct-building helper public (dialect precedence, date parsing, defaults).
- Rewrite `mix models.update` as verbatim snapshot capture → `priv/models/models_dev.json`; commit the snapshot; delete the per-provider JSON files.
- `Omni.Sources.ModelsDev`: snapshot read + per-boot memoization + relocated transform (eligibility filters, `@npm_to_dialect`, renames `moonshotai`/`ollama-cloud`), skip + warn per bad model with per-provider summary, `{:error, :unknown_provider}` for missing catalog keys.
- Rework `Omni.Provider.load_models/2`: `(module, opts)` signature, source resolution ladder, normalization of `module | {module, opts} | :models_dev | :llm_db`, warn + empty on source error, deprecation raise for binary second argument.
- Config reshape: `:providers` keyword shape (`source:`, `load:`, default `:all`), legacy-shape raise, per-module `source:` override; update `Omni.Application`.
- Update built-in providers' `models/0` to `load_models(__MODULE__)`; Ollama and Venice keep their post-processing.
- CI golden test; resolution/stub-source tests; one-off dev-time diff against the old curated files before deleting them.

**Done when:** boot from the snapshot yields the expected model set (golden test green); legacy config raises helpfully; a stub source can be injected via config.

### Phase 3 — LLMDB source

- `Omni.Sources.LLMDB` with optional-dep guards (`ensure_loaded?`, `no_warn_undefined`, `ensure_all_started`, raise-if-selected-but-absent).
- Relocate the prototype transform (filters, reasoning workaround with non-empty list checks, dialect cascade ending in `module.dialect()`, alias expansion with canonical-wins dedupe, cost clamps, per-model rescue); renames `:moonshotai`/`:ollama_cloud`; `{:error, :unknown_provider}` mapping.
- Re-run the prototype diff to settle the OpenCode fallback question.
- Delete `mix models.update_llmdb` and the gitignored `priv/models-llmdb/` reference.
- Transform unit tests; end-to-end `source: :llm_db` test; compile-without-llm_db check.
- Docs: pointers to `config :llm_db` for filtering/freshness; known upstream data issues noted.

**Done when:** `source: :llm_db` boots and loads a model set comparable to the prototype's validated output; Omni compiles and tests green without llm_db installed.

### Phase 4 — ModelsDev live mode

The only phase with genuinely new machinery.

- `live:`, `cache_dir:`, `cache_ttl:` opts on `Omni.Sources.ModelsDev` (no timeout opt — fixed ~5s budget).
- Resilience ladder: fresh cache → fetch (fixed timeout, write-temp-then-rename cache) → stale cache (warn) → bundled snapshot (warn).
- `Req.Test`-stubbed tests for the full ladder.
- Docs: boot-time egress note; cache location semantics.

**Done when:** live mode survives models.dev being unreachable with at worst a stale-data warning; boot latency bounded by the fetch timeout.

### Phase 5 — Documentation and release

- Rewrite the model-data sections of `context/design.md`; update README (source configuration, live mode, llm_db); update `CLAUDE.md` (task description, conventions); clean up the roadmap entry.
- CHANGELOG with migration guide for the config break; version bump (final call at release time — see "Breaking changes and migration").
- Side task (non-blocking, any time): report the two llm_db upstream data bugs with reproducible model lists.

**Done when:** docs describe the shipped behavior end-to-end; release prepped.
