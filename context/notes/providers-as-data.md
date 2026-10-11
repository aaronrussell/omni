# Providers as data — v2.0 design (pass one)

*2026-10-10. Outcome of a design conversation about replacing provider modules with provider data for Omni v2.0.0. This records the shape we landed on, why, and what was deliberately left for later passes. It is a broad shape, not an implementation plan.*

## The problem

Omni separates dialects (wire format) from providers (endpoint, auth, quirks). Dialects are modules, and that is right: they are code. Providers are also modules, and that is the thing being changed.

A provider is mostly three values — a base URL, an API key source, a dialect — plus, sometimes, a quirk. Making every provider a module means:

- Omni can never offer the hundreds of OpenAI-compatible endpoints that exist without writing hundreds of modules.
- Users cannot add a provider without writing code, even when the catalog already knows it.
- The module is the identity everywhere: app config is keyed by module, `:persistent_term` is keyed by what the module reports, `Omni.Source.fetch/2` takes a module, `Model.to_ref/1` calls `module.id()`.

Two further problems came out of auditing what the thirteen built-in modules actually do:

- **`modify_body/3` is a post-hoc rewrite coupled to dialect internals.** Every implementation pattern-matches keys the dialect emitted (`"reasoning_effort"`, `"response_format"`, `"max_completion_tokens"`) and undoes them. The design says providers don't know the body shape; the code says otherwise.
- **The dialect/provider boundary had already eroded from the other side.** `Omni.Dialects.OpenAICompletions` knows about OpenRouter and vLLM (`"reasoning"` vs `"reasoning_content"`), Z.ai (non-standard finish reasons), and Venice (packed chunks). Variation that belongs in one place ended up in the dialect anyway, which is evidence for putting it there on purpose.

### What the thirteen modules do

| Provider | Pure config? | Overrides | What for |
|---|---|---|---|
| Anthropic, Google, OpenAI | yes | — | — |
| Groq | | `modify_body` | clamp `reasoning_effort` per model family, add `reasoning_format` |
| Moonshot | | `modify_body` | `reasoning_effort` → `thinking.type` |
| Alibaba | | `modify_body` | `reasoning_effort` → `enable_thinking` + budget; `json_schema` → `json_object` + prompt |
| Z.ai | | `build_url`, `modify_body` | `/v1` → `/v4`; `reasoning_effort` → `thinking.type`; `json_schema` → `json_object` + prompt; `file` → `file_url` |
| NearAI | | `modify_body` | `max_completion_tokens` → `max_tokens`; drop `prompt_cache_retention`, `reasoning_effort`, `store`; drop `strict` |
| Venice | | `models`, `modify_body` | add `:pdf` to every model; `reasoning_effort: "none"` → `reasoning.enabled: false` |
| OpenRouter | | `modify_body`, `modify_events` | `reasoning_effort` → `reasoning.effort`; `reasoning_details` round trip; error extraction |
| OpenCode | | `build_url`, `authenticate` | `/v1beta` → `/v1`; auth header depends on URL path |
| Ollama Cloud | | `models` | re-stamp dialect to `OllamaChat` |
| Ollama (local) | | `models`, `authenticate` | config-driven model list; no auth |

The quirks cluster into a few repeating axes (reasoning encoding, structured output mechanism, field compatibility, attachment shape), one per-model clamp (Groq), one genuine one-off (OpenRouter), and a set of URL and auth overrides that turn out to be convention problems rather than quirks.

### Catalog facts that shaped the design (bundled models.dev snapshot)

- 225 providers, 8,466 models, 7,137 passing the eligibility filter. 185 providers are `@ai-sdk/openai-compatible`.
- 200 providers carry `api` (base URL). The 25 without are the ones with their own AI SDK package — anthropic, openai, google, groq, venice, mistral, xai, togetherai, cerebras, and so on. Omni must supply those itself.
- 190 of those 200 base URLs include the version segment (`.../v1`). Omni's convention of stripping it is the odd one out; both `build_url` overrides exist only to patch that mismatch.
- Every provider lists `env`. Only 14 list more than one variable, and only Google's is a genuine list of alternatives. The other 13 (Bedrock, Azure, Vertex, Cloudflare, Databricks, Snowflake, …) list *different* values the provider needs, which is a reliable signal that the provider needs bespoke handling.
- The `npm` → dialect table covers the thirteen built-ins. Bespoke packages (`@ai-sdk/mistral`, `@ai-sdk/xai`, `@ai-sdk/togetherai`, …) are unmapped.

### What Pi does

Pi (`@mariozechner/pi-ai`) was the reference point for the quirk mechanism. Each model record has `api` (dialect), `baseUrl`, `provider`, and an optional `compat` object. The openai-completions compat type has 27 flags; the Responses and Anthropic dialects have their own (10 and 13). Defaults are auto-detected in code from provider name and base URL; explicit `compat` wins field by field. There is no hook mechanism: every quirk is a flag and all quirk code lives in the dialect.

Lessons taken: flags scale to hundreds of providers; every dialect needs a flag set, not only completions; auto-detecting from URL is fragile (a user who overrides a region silently loses quirks), so defaults should come from a data table keyed by id instead; and Pi mixes shape-named flags (`maxTokensField`) with provider-named ones (`thinkingFormat: "zai"`), a choice we make deliberately below.

## The shape

### Provider struct

```elixir
%Omni.Provider{
  id: :groq,                                   # canonical id: models.dev key, snake_cased
  name: "Groq",
  base_url: "https://api.groq.com/openai/v1",  # includes the version segment
  api_key: {:system, "GROQ_API_KEY"},          # string | {:system, var} | {M, F, A} | nil
  auth: :bearer,                               # :bearer | {:header, name} | :none | :dialect
  headers: %{},
  dialects: %{text: Omni.Dialects.OpenAICompletions},  # default dialects; nil for gateways
  compat: %{},                                 # quirk flags the dialect understands
  adapter: nil,                                # optional module for quirks that need code
  tier: :verified                              # :verified | :catalog | :custom — introspection only
}
```

- **`base_url` includes the version segment.** Dialect paths become `/chat/completions`, `/messages`, `/responses`, `/models/{id}:streamGenerateContent`. This follows the catalog and the OpenAI SDK convention and removes both URL overrides. Ollama's documented root has no version, so its dialect path stays `/api/chat`.
- **`auth` is pure data.** `:dialect` means "use the header this dialect's home API uses" (Anthropic Messages → `x-api-key`, Gemini → `x-goog-api-key`, OpenAI → bearer). It removes OpenCode's only code, since Zen mirrors each upstream's header. No function-valued forms; anything exotic goes through the adapter.
- **`dialects` is a map** keyed by capability. `:text` is the only key this work defines. This lays groundwork for the Decisions API thread (see `decisions-api.md`) without pulling anything else from it in.
- **`tier`** records how the struct was assembled. It carries no behaviour.

### Three overlays

A provider struct is assembled once, when it loads, from three layers, lowest precedence first:

1. **Catalog** — `api`, `env`, `npm` from the configured `Omni.Source`. Yields a usable struct for ~200 providers with zero Omni code.
2. **`Omni.Provider.Builtins`** — a data table keyed by id: the verified tier. Supplies missing base URLs, Omni's preferred env names, `compat`, and `adapter`. This table *is* the built-in provider list; it replaces the thirteen modules.
3. **User config** — `config :omni, :providers, zai: [...]`. Overrides anything, and defines providers no catalog knows.

At request time nothing is looked up. The model carries the provider, which carries `compat` and `adapter`. Only the API key value and call-site options are resolved per request. User config is therefore baked in at load; changing it after boot means reloading the provider.

### Model struct

```elixir
%Omni.Model{
  provider: %Omni.Provider{},                  # embedded, not an id
  dialects: %{text: Omni.Dialects.OpenAICompletions},  # effective; always filled
  ...                                          # unchanged: id, name, costs, limits, modalities
}
```

`provider.dialects` is the **default**; `model.dialects` is the **effective** value. `dialects` is optional in the input to `Model.new/1` and copied from the provider when absent, so the struct always has it. Gateways like OpenCode have `provider.dialects: nil` and per-model dialects from catalog data. The request pipeline reads `model.dialects.text` and `model.provider`, nothing else.

Dialect precedence when building models flips from today: a provider's explicitly declared dialect wins over catalog inference, and the catalog fills `nil`. Nothing relies on the current order — every single-dialect built-in agrees with the catalog — and the flip removes Ollama Cloud's `models/0` override.

### Quirks: two mechanisms

**Compat flags** for shared axes. Each dialect declares `compat_schema/0`; the provider's `compat` map is validated against it when the provider loads, so a typo is a boot error. The dialect reads flags at the encoding step, so `encode_thinking/2` emits `%{"thinking" => %{"type" => "enabled"}}` directly instead of emitting `reasoning_effort` for something to rewrite later. Every dialect has a schema, empty where nothing is needed yet — Pi's experience says they all grow.

Flags are **named by wire shape, never by provider**. If two providers share a shape they share a value; declaring something "the Z.ai way" when Moonshot does the same thing is a claim we have no standing to make. The price is that some shapes get awkward names (Venice's "effort for positive levels, `reasoning.enabled: false` to disable" needs something like `:effort_or_enabled`). Worth paying.

A `like: :groq` key in a provider's compat config copies a verified provider's compat map; the user's own flags overlay it. It copies compat only — not adapter, not base URL.

Provisional sketch of the flags the thirteen built-ins need (OpenAI Completions dialect). **This is a sketch to show the shape works, not a decision** — see "Deferred".

| Flag | Values | Needed by |
|---|---|---|
| `reasoning` | `:effort`, `:thinking_type`, `:enable_thinking`, `:reasoning_object`, `:none` | Moonshot, Z.ai, Alibaba, OpenRouter, NearAI |
| `structured_output` | `:json_schema`, `:json_object_prompt` | Alibaba, Z.ai |
| `strict_schema` | boolean | NearAI |
| `max_tokens_field` | `"max_completion_tokens"`, `"max_tokens"` | NearAI |
| `prompt_cache` | boolean | NearAI |
| `store` | boolean | NearAI |
| `attachments` | `:file`, `:file_url` | Z.ai |

**Adapter modules** for everything else: one-offs, anything that varies per model within a provider, exotic auth, model-list changes. The rule is simple: *flags are provider-level only; if a quirk depends on anything model-specific, it is adapter code*. This rule is deliberately unresolved — see "Compat that varies within a provider" under Deferred. An adapter is a module named in the struct's `adapter` field and declaring `@behaviour Omni.Provider`, with four optional callbacks, each skipped when not defined:

```elixir
load(models, provider) -> models
# Once, when the provider's models load. Receives what the source returned,
# returns the final list. Venice adds :pdf here.

modify_request(req, provider, opts) -> {:ok, req} | {:error, reason}
# Last touch on the finished %Req.Request{}. Runs after the data `auth`
# step and may overwrite it: request signing (Bedrock), token fetch (Vertex),
# query params. Keeps the ok/error return because credential resolution
# depends on external state that can be missing at request time.

modify_body(body, model, context, opts) -> body
# Receives the model because Gemini carries the model id in the URL, not
# the body, and because model.provider.compat is useful here.

modify_deltas(deltas, raw_event, model) -> deltas
# Named for what it modifies. In Omni's vocabulary the dialect's
# handle_event(raw_event) emits deltas; "events" was ambiguous.
```

Of today's thirteen providers, three keep an adapter: OpenRouter (`reasoning_details` round trip), Groq (per-model effort clamp), Venice (`:pdf` on every model). Ten become table entries with no code. Alibaba, Moonshot, Z.ai and NearAI are compat flags; OpenCode, Ollama and Ollama Cloud dissolve into struct fields and the precedence flip.

Naming convention: `Omni.Provider` is the struct, the adapter behaviour, and shared machinery (`Omni.Provider.*` if that machinery needs splitting). `Omni.Providers.*` is reserved for adapter implementations. `Omni.Provider.Builtins` is the table.

### Configuration

```elixir
# Configure providers. Entries for providers that are not loaded are ignored.
config :omni, :providers,
  anthropic: [api_key: {:system, "MY_KEY"}],
  fireworks_ai: [compat: [like: :groq]],
  ollama: [models: ["llama3.1:8b", [id: "qwen3.5:4b", context_size: 32_768, reasoning: true]]],
  gpu_box: [
    base_url: "http://gpu-box:8000/v1",
    dialects: %{text: Omni.Dialects.OpenAICompletions},
    auth: :none,
    models: [[id: "llama-3.3-70b", context_size: 128_000]]
  ],
  openai: [models: [[id: "ft:gpt-4o:acme::abc123", context_size: 128_000]]]

# Select what loads.
config :omni, :models,
  providers: [:builtins, :fireworks_ai, :gpu_box],   # default [:builtins]
  source: Omni.Sources.ModelsDev,
  filter: {MyApp.Models, :keep?}                      # or &MyApp.Models.keep?/1
```

- **`:providers` configures; `:models` selects.** Both keys exist today. Configuring is never enabling, so "does setting compat turn a provider on?" has a plain answer: no. Disabling a built-in is listing `providers:` without `:builtins`.
- **Dialects are module names** in config. A user's own dialect module works with no registration step. String ids (`"openai_completions"`) remain an internal detail for reading catalog data.
- **`models:`** is a general per-provider key for defining models, built through `Model.new/1` and stamped with the provider. It is *additive* to the catalog: a custom provider has nothing else, local Ollama has nothing else, and a fine-tune on OpenAI sits beside the catalog models. Removal is the filter's job.
- **`filter:`** is a predicate over the finished `%Model{}` (provider embedded), run at load. `{Mod, :fun}` or a named capture; anonymous functions don't survive compile-time config and the docs say so. No glob DSL to design.
- **Nothing is guessed.** A selected catalog provider with no base URL fails at boot with "set `base_url:`"; one whose npm package maps to no dialect fails with "set `dialects:`"; one listing several env vars fails with "set `api_key:`". A wrong dialect produces confusing errors far from the cause, so refusing beats defaulting.
- **Not-loaded vs unknown.** `Omni.get_model(:fireworks_ai, "x")` returns `{:error, {:provider_not_enabled, :fireworks_ai}}` when the catalog knows the id, `{:error, {:unknown_provider, :foo}}` when nothing does. Both up front, never at request time.

### Loading

Eager at boot for the selected providers, as today, into `:persistent_term`: one map of provider structs keyed by id (`Omni.get_provider/1` becomes possible), and one map of models per provider (`list_models/1` stays O(1); a runtime `put_model` rewrites only one provider's term). `Omni.Provider.load/1` remains for runtime additions. There is no whole-catalog mode; the use case for every model from every provider in one app is unlikely, and the `providers:` list bounds the set.

Memory is not a concern: within one persistent term, all of a provider's models share one copy of the provider struct; reads never copy. The existing caveat stands: writing a changed value to persistent term scans every process heap, so `load` and `put_model` are boot or on-demand operations, never per request.

### Request pipeline

- `Request.validate/2` merges two tiers instead of three: the provider struct (which already absorbed user config), then call-site options.
- URL is `provider.base_url <> dialect.handle_path(model, opts)`; no override point.
- Auth is applied from `provider.auth` as data, then `adapter.modify_request/3` if present.
- Body is `dialect.handle_body/3` (reading `model.provider.compat`), then `adapter.modify_body/4` if present.
- Deltas are `dialect.handle_event/1`, then `adapter.modify_deltas/3` if present.

### Source behaviour

The concept is unchanged: a source answers "give me the models for this provider". Two shape changes, allowed because the behaviour is marked experimental and at least one external user depends on the concept rather than the signature:

- `fetch/2` receives the `%Omni.Provider{}` instead of a module and stamps it on the models it builds.
- A new callback (working name `provider/2`) returns the catalog's provider-level data normalised to `%{base_url, api_key_env, dialect}`, or `{:error, :unknown_provider}`. This is overlay one.

`with_cache/1` and `memo/2` stay as they are.

## Rejected along the way

- **Function hooks as struct fields** (`modify_body: &Mod.fun/3`). Solves identity, keeps post-hoc rewriting, nothing becomes expressible in config, and closures can't live in compile-time config.
- **Central quirk registry keyed by id or base URL.** Action at a distance; base URL matching breaks on region overrides. Pi's auto-detect is this, and it is the part of Pi not to copy.
- **Naming-enables config** (`fireworks_ai: []` turns the provider on). Conflates configuring with enabling, needs a separate mechanism to disable built-ins, and reserved keys like `enabled:` would sit beside provider ids.
- **`api_key` as a list of candidates.** Only Google has genuine alternatives; the table picks one. Code for the sake of code.
- **Adapter lookup by naming convention.** The table names the module explicitly; no magic needed even for built-ins.
- **Per-model compat overrides.** Replaced by the rule that model-specific variation is adapter code.
- **Lazy per-provider loading.** Only needed for a whole-catalog mode, which was dropped.

## Deferred — each its own pass

- **Compat flag research.** Survey Pi, llm_db, the Vercel AI SDK openai-compatible package, LiteLLM and OpenRouter's normalisation layer. Ask where they converge and why; note where Omni would differ and whether that is an improvement or a mistake. Decide shape-level questions such as specific booleans vs a generic `drop_fields` list. The seven-flag table above is provisional until this is done.
- **Decisions API.** The `dialects` map is the groundwork. Nothing else from `decisions-api.md` is pulled in here.
- **Compat on non-completions dialects.** Schemas exist but are empty; what goes in them follows from the research pass.
- **Compat that varies within a provider.** The shape above puts `compat` on the provider as a flat map and validates it against one dialect's `compat_schema/0`. Two real cases don't fit that:
  - *Per dialect.* Gateways serve models over different dialects (OpenCode: Anthropic Messages and OpenAI Completions; OpenRouter: Completions or Responses). A flat map has no dialect to validate against, and flags for one wire format are meaningless to the other.
  - *Per model, same dialect.* Groq's models share one dialect but differ on which reasoning-effort values each accepts. Today this is adapter code; the rule above says it stays that way.
  Directions raised but not settled: key the provider's `compat` by dialect module (flat map as sugar for "my default dialect"); carry an effective `compat` on the model, mirroring `dialects` (provider default, model effective, validated per model against its own dialect, settable via `models:` config, `Model.new/1`, or an adapter's `load`); or both. Whatever lands, `Omni.Provider.Builtins` needs some multi-dimensional way to express it. Some "per model" quirks may actually be model capability facts rather than compat flags, which the research pass should draw out. Decide this alongside the compat flag research, not before it.

## Small open points

- Ten of 200 catalog base URLs lack a version segment (`https://api.deepseek.com`, `https://api.novita.ai/openai`). Fix via table entries as they are verified; untested catalog providers with odd roots may need `base_url:` in config.
- Whether `Omni.Provider.Builtins` should also map bespoke npm packages that are OpenAI-compatible in practice (`@ai-sdk/mistral`, `@ai-sdk/xai`, …), or whether that belongs in the source's inference table. Either way it resolves the parked "OpenCode Mistral" roadmap item.
- Exact error term names (`:provider_not_enabled`) and the `tier` field name are placeholders.

## What this touches

For planning only; breaking changes are expected in v2.0.0 and `omni_agent` will be dealt with separately.

- `Omni.Model`: `provider` becomes a struct, `dialect` becomes `dialects`, `to_ref/1` reads `provider.id`.
- `Omni.Provider`: rewritten as struct + behaviour + machinery. `Omni.Provider.Builtins` is new. Thirteen modules become three adapters.
- `Omni.Request`: two-tier merge, data auth, adapter hooks, no `build_url`.
- `Omni.Dialect`: `compat_schema/0` callback; paths lose their version prefix; dialects read `model.provider.compat`.
- `Omni.Source` and both sources: new signatures and the provider-level callback.
- `Omni.Application`: `:models` config gains `filter:`; `:providers` config is read for per-id settings.
- Config: `config :omni, Omni.Providers.X` becomes `config :omni, :providers, x: [...]`; configured `base_url` values gain a version segment.
- Tests: 32 files reference `provider:` or `.provider`; integration tests build structs instead of referencing modules.
