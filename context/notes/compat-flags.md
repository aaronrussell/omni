# Compat flags — research outcome

*2026-10-15. Outcome of the compat research session defined in `providers-as-data-plan.md`. Surveys Pi, the Vercel AI SDK, LiteLLM, OpenRouter, llm_db and req_llm, then records the flag set, where compat lives, the `handle_event` signature, and what remains adapter code. Supersedes the provisional seven-flag table and the "Compat that varies within a provider" deferred item in `providers-as-data.md`.*

> **Phase 1 adjustments (2026-10-16).** There is no `Omni.Provider.Builtins` data table: built-in compat will live in each built-in module's `config/0`, keyed by dialect as below. Dialect precedence also changed: model data decides each model's dialect and the provider's list is derived from its models (see the phase 1 section of `providers-as-data-plan.md`), replacing "the catalog's dialect if in the list, otherwise the first". Flexible routing (`Model.put_dialect/3`) moves to phase 4.

> **Phase 2 adjustments (2026-10-16).** Model capability data is a single field, `%Omni.Model{thinking: false | true | %{efforts, toggle, budget}}`, replacing `reasoning`; resolution is shared in `Omni.Dialect.Thinking` and used by all five dialects (not only Completions). `thinking: true` is dynamic thinking. With no data and a toggle format set, the Completions dialect uses the toggle (preserving pre-phase-2 behaviour). Built-in modules key compat by dialect in `config/0`; user config may use a flat list for single-dialect providers. `thinking_replay_field: "reasoning_content"` (Moonshot) was not added: the suspected replay bug didn't reproduce live. The `_format` enums include their home values. See `providers-as-data-phase2.md`.

## What the research found

Two points of convergence shaped everything else.

**Wire spelling and model capability are separate things.** Every library that models reasoning limits splits *how an endpoint spells reasoning* (wire format) from *which levels a model accepts* (a fact about the model). The second is model data everywhere it is modelled at all:

| Library | Where per-model effort levels live |
|---|---|
| Pi | Model field `thinkingLevelMap`, generated from models.dev `reasoning_options` |
| OpenRouter | Its models API: `reasoning.supported_efforts`, `mandatory`, `default_effort` |
| LiteLLM | Model JSON `reasoning_effort_levels`, plus a nearest-level snapping function |
| llm_db | `extra.reasoning_options`, passed through from models.dev; typed `capabilities.reasoning.effort` only on hand-curated Anthropic and OpenAI records |
| Vercel, req_llm | Model-id regexes and sets in code; both reports call this the weak part |

Omni's bundled models.dev snapshot already carries `reasoning_options` on 6,255 of 8,466 models: `{type: "effort", values: [...]}`, `{type: "toggle"}`, `{type: "budget_tokens", min, max}`. Groq gpt-oss is `effort: [low, medium, high]`; Groq Qwen is `[none, default]`; Moonshot and Z.ai are mostly `toggle`; Alibaba is mostly `toggle` plus `budget_tokens`.

**Parsing is tolerant everywhere.** No library uses compat flags to parse OpenAI Completions streams. All accept `reasoning_content`, `reasoning` and `reasoning_details` from any provider, and map finish reasons through one union table. The only parse-side flag anywhere is Pi's `supportsFinishReason`. Variation lives on the encode side.

Lessons from the shape of each library's flags: they accrete. Pi's `thinkingFormat` is a closed enum of vendor names that mixes spelling with capability; Vercel's generic package exposes four settings, so six of its eleven bespoke packages reimplement; LiteLLM's `drop_params` hides capability gaps; req_llm has no flag layer at all, so every quirk is a module. Following prior art lets Omni design the set as a whole instead.

## Flag design

### The default is the dialect's home API

No flag means "behave exactly as the API this dialect is named after". For OpenAI Completions that is OpenAI's own Chat Completions API. A flag exists only to describe a deviation from it. No flag takes `nil`; absence is the default. A catalog-tier provider "speaks the dialect plain", which now means "no flags, home-API behaviour".

### Four kinds of flag

Every quirk does one of four things to the request body. The name pattern and value type say which.

| Kind | Name | Value | Reads as |
|---|---|---|---|
| Rename | `<subject>_field` | string: literal wire path, dots for nesting | "put it here instead" |
| Reshape | `<subject>_format` | atom: a named alternative shape the dialect documents | "use this shape instead" |
| Drop | `omit` | list of atoms naming Omni concepts | "don't send these" |
| Add | `extra_body` | string-keyed map of literal wire fields | "also send these" |

The principle under all four: **Omni's vocabulary where Omni has the concept; literal wire text where it doesn't.** Subjects are Omni's names (`thinking` for the `:thinking` option and `Thinking` blocks, `output` for `:output`, `attachment` for `Attachment`, `max_tokens` for `:max_tokens`). `omit` removes things Omni put into the body, so its atoms name the Omni concept being dropped. `extra_body` adds things Omni has no concept of, so it is literal. A string value is always literal wire text; an atom is always a named thing the dialect validates.

Flags are flat, with a shared prefix for grouping, not nested. The overlay merge rule merges `compat` shallowly by key; nesting would force a deep merge or let one user key wipe out a borrowed `like:` set.

Flag *names* follow the settled rule: named by wire shape or Omni concept, never by provider.

### Not a generic `drop_fields`

`omit` is a validated list of things the dialect knows how to remove wherever they sit (strict schemas sit three levels deep), not a list of raw body keys. A typo fails at boot. It also gives the parked warning mechanism its sentence for free: "this provider ignores `:cache`".

### Ship rule

A flag ships only with a verified provider that exercises it. Prior art says which flags to expect; only a live endpoint proves the flag works. This keeps the catalog-tier promise honest: plain dialect, plus any flag in the schema, each verified against a real endpoint somewhere. The flag set grows with the Builtins table, not ahead of it.

## Flag table — OpenAI Completions

| Flag | Absent (home API) | Values | What setting it does | Built-ins |
|---|---|---|---|---|
| `max_tokens_field` | `"max_completion_tokens"` | `"max_tokens"` | Sends the `:max_tokens` value under another key | NearAI |
| `thinking_effort_field` | `"reasoning_effort"` | `"reasoning.effort"` | Sends the effort level under another key or nesting | OpenRouter |
| `thinking_budget_field` | no budget sent | `"thinking_budget"`, `"reasoning.max_tokens"` | Sends a token budget, for models whose capability data says they take one | Alibaba |
| `thinking_replay_field` | earlier reasoning not sent back, nor captured | `"reasoning_content"`, `"reasoning_details"` | Captures reasoning of that kind from responses and sends it back on assistant messages in this field | OpenRouter |
| `thinking_toggle_format` | off is `reasoning_effort: "none"`; no on-switch | `:thinking_type`, `:enable_thinking`, `:reasoning_enabled` | Changes how thinking is switched on and off | Moonshot, Z.ai, Alibaba, Venice |
| `output_format` | `:json_schema` | `:json_object` | Uses JSON mode and puts the schema in the system prompt | Alibaba, Z.ai |
| `attachment_format` | `:file` | `:file_url` | Wraps non-image files in a `file_url` content part instead of `file` | Z.ai |
| `omit` | `[]` | `:cache`, `:thinking`, `:strict_schema` | Never sends these | NearAI |
| `extra_body` | `%{}` | any string-keyed map | Merges literal fields into the body | none yet |

Wire shapes behind the `_format` atoms:

- `thinking_toggle_format`: `:thinking_type` → `thinking: {type: "enabled" | "disabled"}`; `:enable_thinking` → `enable_thinking: true | false`; `:reasoning_enabled` → `reasoning: {enabled: true | false}`.
- `output_format`: `:json_object` → `response_format: {type: "json_object"}` plus the schema described in the system prompt. A forced-tool mechanism (Groq, Fireworks and req_llm's default elsewhere) is the known third value; add it when a verified provider needs it.
- `attachment_format`: `:file` → `{type: "file", file: {file_data: <data URI>}}`; `:file_url` → `{type: "file_url", file_url: {url: <data URI>}}`.

`omit` atoms: `:cache` drops whatever the `:cache` option would send; `:thinking` drops everything the `:thinking` option would send, whatever the `thinking_*` spelling; `:strict_schema` drops the strictness Omni applies to output schemas.

### How thinking encodes

Flags say how to spell; the model's capability data says what to send. For a request with `:thinking` set, on a model with reasoning:

1. `omit` contains `:thinking` → send nothing.
2. Off requested → if the model can be switched off (toggle type, `"none"` in its effort values, or no data), spell it with `thinking_toggle_format`. If it cannot (reasoning is mandatory), send nothing.
3. On, and the model is effort type → clamp the level to the model's values and send it at `thinking_effort_field`.
4. On, and the model is toggle type → switch on with `thinking_toggle_format`, plus a budget at `thinking_budget_field` when the model takes one and the flag is set.
5. No capability data → today's behaviour: effort, all levels.

This one rule replaces pass one's `:effort_or_enabled` for Venice (effort type: levels go to the effort field, off uses the toggle) and covers providers where some models take effort and most take a toggle (Moonshot, Z.ai, Alibaba).

Clamping is shared, not per dialect: round up to the nearest supported level, else down, never across on/off (LiteLLM's and Pi's rule). It fixes two current bugs: `:max → "xhigh"` is wrong where a model lists `max` but not `xhigh`, and `thinking: false → "none"` is rejected by gpt-oss.

### Built-in values

| Provider | `compat` (Completions) |
|---|---|
| OpenAI, Groq, Ollama Cloud | none |
| Moonshot | `thinking_toggle_format: :thinking_type` |
| Z.ai | `thinking_toggle_format: :thinking_type`, `output_format: :json_object`, `attachment_format: :file_url` |
| Alibaba | `thinking_toggle_format: :enable_thinking`, `thinking_budget_field: "thinking_budget"`, `output_format: :json_object` |
| NearAI | `max_tokens_field: "max_tokens"`, `omit: [:cache, :thinking, :strict_schema]` |
| Venice | `thinking_toggle_format: :reasoning_enabled` |
| OpenRouter | `thinking_effort_field: "reasoning.effort"`, `thinking_replay_field: "reasoning_details"` |

Anthropic, Google, OpenCode and local Ollama need no flags on any dialect.

## Other dialects

Anthropic Messages, OpenAI Responses, Google Gemini and Ollama Chat ship with empty `compat_schema/0`. No verified built-in needs a flag on them. That is the ship rule at work, not an exclusion: the catalog has about eight Anthropic Messages providers (MiniMax and its variants, freemodel, subconscious, thinkingmachines), about six Responses providers (infer, meta, neosmith, perplexity-agent, vivgrid), and gateways that route individual models over both. They load and speak their dialect plain. Whether they need quirks is unknown, not known-clean.

Candidates from prior art, to adopt when a verified provider needs them (named here in the source library's terms; Omni names follow the patterns above):

- **Anthropic Messages** (Pi, seen on Fireworks' and OpenRouter's Anthropic endpoints): empty thinking signatures allowed; no `cache_control` on tools; no eager tool-input streaming; temperature unsupported; adaptive thinking forced.
- **OpenAI Responses** (Pi, seen on xAI and OpenRouter): no long cache retention; no developer role; `store: true` rejected.

Verifying MiniMax (Anthropic) or xAI (Responses) in phase 4 is the way to grow these.

## Where compat lives

Compat lives on the provider only, keyed by dialect module. Models carry no compat; they select a dialect per capability from the provider's list.

```elixir
%Omni.Provider{
  dialects: %{text: [OpenAICompletions, AnthropicMessages], decision: [SystemOne]},
  compat:   %{OpenAICompletions => %{...}, AnthropicMessages => %{...}}
}

%Omni.Model{
  dialects: %{text: AnthropicMessages, decision: SystemOne}   # one per capability
}

# at request time
compat = model.provider.compat[model.dialects.text]
```

- **One canonical table.** `Omni.Provider.Builtins`, keyed by provider id, each entry carrying `dialects` and `compat`. User config overlays the same keys. `like:` copies a verified provider's whole `compat` map.
- **Three provider cases, no special handling.** Basic: one dialect in the list. Gateway (OpenCode): the catalog picks each model's dialect from the list. Flexible (OpenRouter serving one model over Completions, Responses or Messages): `Model.put_dialect/3` switches to another dialect in the list.
- **Dialect precedence for a model.** The catalog's inferred dialect if it is in the provider's list, otherwise the first in the list. With a one-item list this is phase 1's "provider wins" flip unchanged.
- **Validation at load.** Every `compat` key is a dialect the provider lists; each map passes that module's `compat_schema/0`; every model's dialect is in its provider's list for that capability.
- **Decisions API.** A decision dialect is another module key; no special case.

**Per-model compat is ruled out.** What looked like per-model variation in the research resolves elsewhere:

| Variation | Resolved by |
|---|---|
| Groq effort levels; effort-vs-toggle models on Moonshot, Z.ai, Alibaba | Model capability data |
| OpenRouter `anthropic/*` cache-control format (Pi) | Flexible case: route those models over Anthropic Messages |
| Together's four variants, DeepSeek V4 replay | Not built-ins; settle on verification |
| Anything genuinely per-model that remains | Adapter code, which sees the model |

The cost: `extra_body` is provider-wide and unconditional. A field only some models accept is adapter code.

### Model capability data

What lets compat stay provider-only is that `%Omni.Model{}` gains reasoning capability data: effort values, whether it toggles, budget range. Both sources read it: models.dev `reasoning_options`; llm_db's `extra.reasoning_options`, typed `capabilities.reasoning`, and OpenRouter's `extra.reasoning` (`supported_efforts`, `mandatory`). The field shape is a phase 1 or 2 design question, since `%Model{}` is already being reworked in phase 1.

## Parsing and `handle_event`

**Parse tolerantly, encode by flag.** The Completions parser stays a union: `reasoning_content` or `reasoning`, every known finish reason, packed chunks, in-stream errors. No parse-side flags.

The one parse-side read of compat is capture for replay: when `thinking_replay_field` is `"reasoning_details"`, the dialect stashes `reasoning_details` into `Message.private`. Capture and replay are governed by the same flag, so data is collected only when it will be sent back. That requires the dialect to see compat at parse time:

```elixir
@callback handle_event(event :: map(), Model.t()) :: [delta]
```

`modify_deltas` does not survive; OpenRouter's in-stream error extraction already duplicates the dialect's first `handle_event` clause, and its `reasoning_details` handling moves into the dialect behind the flag.

Not adopted: a stateful parse hook (init, per-event state, flush) for reasoning streamed inline as `<think>…</think>` text, as req_llm does for Groq. No verified provider needs it; adding it is a separate change.

## What remains adapter code

| Provider | Residue |
|---|---|
| Venice | `load`: add `:pdf` to every model |
| Groq | Possibly `modify_body` for `reasoning_format: "parsed"`, depending on verification (below) |

Everything else becomes flags, capability data or struct fields. The adapter behaviour likely settles at `load` and `modify_request`, with `modify_body` only if Groq needs it. Phase 2 decides against this residue.

## Changes to other notes

- **Phase 1 (`providers-as-data-plan.md`).** `provider.dialects` values are lists of supported dialects per capability, not a single module; gateways list theirs instead of carrying `nil`. Dialect precedence follows the rule above. `Model.put_dialect/3` is new.
- **Pass one (`providers-as-data.md`).** The seven-flag table, the flat-map `compat`, and the "Compat that varies within a provider" deferred item are superseded by this note. The rule "flags are provider-level; model-specific variation is adapter code or model data" stands, now with model data defined.

## To verify in phase 2

- **Moonshot and Z.ai `max_tokens`.** Pi switches both to `max_tokens`; Omni sends `max_completion_tokens`, which they may silently ignore.
- **Effort-type models on Moonshot, Z.ai, Alibaba.** The thinking rule sends them `reasoning_effort` instead of today's toggle. Vercel says Kimi K3 rejects `thinking` and takes effort, so this is likely a fix, but check each.
- **Groq `reasoning_format`.** Whether it is needed at all, on which models, and whether non-reasoning models reject it. Decides whether Groq keeps `modify_body`.
- **Alibaba structured output.** req_llm sends strict `json_schema`; the catalog marks 16 of 59 models as supporting structured output. The `json_object` fallback may be stale for some models.
- **Groq Qwen's `"default"` effort.** A wire value outside Omni's levels; the clamp needs a rule for it (Pi hand-maps `high → "default"`).
- **Effort-to-budget mapping.** Alibaba's effort → budget table moves out of the provider; decide where it lives.

## Side findings

- **Moonshot replay.** Kimi models, at least K3, need `reasoning_content` sent back on assistant messages in tool loops (Pi, Vercel, LiteLLM all do this). Omni drops Thinking blocks when encoding Completions. Likely a live bug in multi-step tool use; `thinking_replay_field: "reasoning_content"` on Moonshot would fix it once verified.
- **NearAI drops `store`**, which the Completions dialect never sends. Dead code.
- **llm_db `extra` keys (unverified).** Since llm_db 2026.7.2, `extra` keeps JSON string keys. `npm_dialect/1` and `reasoning?/1` in `lib/omni/sources/llmdb.ex` match atom keys and would silently stop matching on upgrade. The lock is on 2026.7.0.
- **OpenRouter models API** is a ready source of per-model reasoning capability (`supported_efforts`, `mandatory`, `default_effort`) and per-endpoint `supported_parameters`. llm_db drops the latter.

## Sources

Research reports were produced against these revisions on 2026-10-15.

- Pi (`@earendil-works/pi-ai` 1.2.0, pi-mono `6a1f799`): `packages/ai/src/providers/compat-schema.ts`, `src/api/openai-completions.ts` (`detectCompat`, `getCompat`, stream loop), `src/providers/model-schema.ts` (`thinkingLevelMap`), `scripts/models-dev-reasoning-options.ts`.
- Vercel AI SDK (`vercel/ai` `46a5d97`): `packages/openai-compatible/src/chat/openai-compatible-chat-language-model.ts`, `packages/provider-utils/src/map-reasoning-to-provider.ts`, `packages/{groq,mistral,xai,deepseek,moonshotai,alibaba,cerebras,fireworks,zai,togetherai}`.
- LiteLLM (`BerriAI/litellm` `d553123`): `litellm/llms/openai_like/providers.json`, `litellm/llms/openai/chat/gpt_transformation.py`, `litellm/router_utils/reasoning_effort_capability.py`, per-provider `chat/transformation.py`.
- OpenRouter: https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md, https://openrouter.ai/docs/api_reference/parameters.md, https://openrouter.ai/docs/api_reference/streaming.md, https://openrouter.ai/api/v1/models.
- llm_db (2026.7.0 locked; 2026.10.5 latest): `lib/llm_db/model.ex`, `lib/llm_db/sources/models_dev.ex`, `priv/llm_db/local/README.md` (`constraints`), `lib/llm_db/execution_contract.ex`.
- req_llm (`agentjido/req_llm` `84fc395`): `lib/req_llm/provider.ex` (decode callbacks), `lib/req_llm/provider/defaults.ex`, `lib/req_llm/providers/{groq,moonshot_ai,cerebras,xai,catalog_gateway}.ex`, `lib/req_llm/providers/openai/param_profiles.ex`.
- Omni catalog: `priv/models/models_dev.json` (`reasoning_options`, `interleaved`, `structured_output`).
