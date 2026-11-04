# Decisions API — design (pass two)

*2026-10-30. The agreed plan, replacing the 2026-10-09 brainstorm. Everything here was settled in discussion; the phases at the end are the order of work. Provider endpoints revised 2026-11-03 after a first implementation, then settled further (no dialect fill, origin-only `host:`, config models merge by id) and landed as phase 1 the same day. Phase 2's encoding details were settled and it landed on 2026-11-03 too (see Encoding and answers), as did phase 3 after a pre-plan pass on the model shape (see Catalog, and Model shape). Phase 4 was settled in a pre-plan pass on 2026-11-04 (see Verification and fixtures). The research behind it (wire formats, hosts, catalog) is summarised rather than reproduced.*

## What we are building

A second capability beside text generation: send one shared input plus a set of independent, typed questions, and get back calibrated probabilities instead of prose. No streaming, no tools, no multi-turn. Two wire formats cover every known host: TypeSafe's **System One** (the de facto open standard, served by TypeSafe, Ollama, OpenRouter, OpenCode Zen, Alibaba, Venice, Cloudflare, Liquid and others) and **OpenAI Decisions** (`gpt-6-luna` only, also proxied by Vercel). Hosts differ in paths, image encoding, option caps and confidence formulas, none of which needs a third dialect: variation is compat flags and tolerant parsing.

The work also restructures the provider so that each dialect it serves has its own endpoint (a whole base URL, plus compat), which fixes the "per-model base URL" backlog item and is needed before OpenCode's catalog data can be refreshed.

```elixir
{:ok, decision} =
  Omni.decide({:openai, "gpt-6-luna"}, {ticket_text, [
    urgent: Omni.predicate("Does this need a reply within the hour?"),
    team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
    anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
  ]})

decision.answers[:urgent]  #=> %Omni.Answer.Predicate{probability: 0.91}
decision.answers[:team]    #=> %Omni.Answer.Choice{choice: :infra, probabilities: [billing: 0.02, infra: 0.95, other: 0.03], confidence: 0.93}
decision.answers[:anger]   #=> %Omni.Answer.Score{score: 1.4, probabilities: [{"Calm", 0.1}, {"Frustrated but civil", 0.4}, {"Very angry", 0.5}], confidence: 0.4}
decision.usage             #=> %Omni.Usage{input_tokens: 174, total_cost: ...}
```

## Wire formats

| | System One | OpenAI Decisions |
|---|---|---|
| Endpoint | `POST <base>/systemone` (TypeSafe `/v1/systemone`; OpenRouter alias `/api/v1/systemone`; Ollama `/v1/systemone`; Zen `/inference/systemone/v1/systemone`) | `POST /v1/decisions` |
| Shared input | `state`: string, object or array. Images vary by host (`assets` map, `images` list, `image_url` parts) | `input`: string, or message items with `input_text`, `input_image`, `input_json` parts |
| Questions | map keyed by caller name: `{type: noul \| choice \| score \| box, instructions, criteria}` | array of 1–400 `{type: predicate \| choice \| score, name?}`; `choices` 2–255 `{value, description?}`; `levels` 2–10 `{label, description?}` |
| Answers | map keyed by name. noul `{noul}`; choice `{choice, probabilities: map, confidence}`; score `{score, legend, probabilities: map keyed by level index, confidence}` | array in question order. predicate `{probability}`; choice `{choice, confidence, probabilities: [{value, probability}]}`; score `{score, confidence, probabilities: [{value, label, probability}]}`; `{type: "refusal", name}` |
| Usage | `input_tokens`, `output_tokens` (Alibaba: input only) | `input_tokens`, `input_tokens_details{cached_tokens, cache_write_tokens}`, `output_tokens`, `output_tokens_details{reasoning_tokens}`, `total_tokens` |
| Extras | OpenRouter adds `id`, `provider`, `usage.cost`; Alibaba `request_id`, `latency_ms`; Cloudflare wraps in `{result}` | `prompt_cache_key`, `prompt_cache_options`, `safety_identifier`; no `id` |
| Streaming | no | no |

Confidence formulas differ (TypeSafe `(p_max − 1/n) / (1 − 1/n)`; Ollama, Upstage and Laya entropy `1 − H/ln N`; Cloudflare its own; OpenAI unspecified). Omni passes the provider's number through and documents that probabilities are the portable contract. Option caps also differ (26 on Upstage and Nimble, 255 elsewhere; score minimum 2 on most hosts; `instructions` required on some). Omni validates the shared floor and lets the provider reject the rest.

## Catalog

Live models.dev with `?type=all` (rechecked 2026-11-03) carries 60 decision models, all `type: "decision"`, all `tool_call: false`; 41 name `@ai-sdk/typesafe-ai` (System One) at model level, 14 `@ai-sdk/openai` (all Vercel), and 5 only a provider-level package (`openai-compatible`, `ai-gateway-provider`). Of Omni's built-ins OpenRouter (33, among them `openai/gpt-6-luna-decisions`, a separate System One id beside the chat model), OpenCode (`jev-1.13`, `jev-1.13-free`) and NearAI (`typesafe/jev-1.13`, `levanto/sage-1.4`) have any. `gpt-6-luna` under `openai` is a plain chat model, since `type` is a single exclusive string. TypeSafe is not a models.dev provider at all (llm_db has it: `https://api.typesafe.ai`, `TYPESAFE_API_KEY`, `jev-1.13.0`, `jev-latest`, `jev-preview`; TypeSafe's docs add `jev-1.14.0`). Ollama Cloud, Alibaba and Venice serve System One but carry no decision models in either catalog.

The default endpoint now carries `type` too, with image, embedding, video, speech, transcription, reranking and realtime models; `?type=chat,decision` returns exactly the untyped, `chat` and `decision` models, and is what the snapshot and live mode fetch.

**Rule: stamp, don't invent.** A built-in module may add a capability to a model the catalog has (OpenAI stamps the decision dialect onto `gpt-6-luna`), and may supply models only for a provider the catalog has no entry for (TypeSafe, like local Ollama). It never adds models to a provider the catalog knows. So Ollama Cloud, Alibaba and Venice wait for catalog data; the paths are documented below for when it lands.

**Hosts in scope**, all with keys to verify:

| Host | Dialect | Endpoint URL | Notes |
|---|---|---|---|
| TypeSafe (new) | System One | `https://api.typesafe.ai/v1` | New `Omni.Providers.TypeSafe`. `models/2` adds TypeSafe's documented models (`jev-1.14.0`, `jev-1.13.0`, `jev-latest`, `jev-preview`) for ids the source and config don't have: config entries are merged in before `models/2` runs, so "only when the catalog returns none" would drop the list as soon as config added a model. System One's home API, so dialect-tier fixtures record here |
| OpenAI | OpenAI Decisions | `https://api.openai.com/v1` | Same URL as the Responses endpoint. `models/2` stamps `decision: Omni.Dialects.OpenAIDecisions` on `gpt-6-luna`. $0.10/M input, cached $0.01 |
| OpenRouter | System One | `https://openrouter.ai/api/v1` (`/systemone`) | 33 catalog models, same URL as the text endpoint, declared in the module so llm_db (which places them at the origin, for the alpha route) gets it too. OpenRouter's SDKs type `/api/alpha/decisions` and `/api/v1/systemone` with the same request and response; the alpha route is marked "shape may change", so Omni uses `/systemone`. Extra response fields ignored |
| OpenCode | System One | `https://opencode.ai/inference/systemone/v1` | From the catalog's model-level URL. The module stops hardcoding `zen/v1` |
| Ollama | System One | `http://localhost:11434/v1` | Config-listed models name `dialects: %{decision: Omni.Dialects.SystemOne}` (no `type:` shorthand: the model has no such field). Chat's endpoint is `http://localhost:11434` (its path is `/api/chat`); `host:` moves both. Images later |
| NearAI | System One | `https://cloud-api.near.ai/v1` | 2 catalog models at the provider URL. Unverified: no key, and NEAR AI doesn't document the endpoint |

Held for catalog data: Ollama Cloud (`https://ollama.com/v1/systemone`, `clef:cloud`), Alibaba (`https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/systemone`, `decision-model-preview`, 16 questions; same API key as chat, so an endpoint on `:alibaba` rather than a second provider), Venice (`/api/v1/systemone` alias, `jev-latest`, `clef`, `clef-api`). Not built-ins: Cloudflare, Vercel, nano-gpt, vivgrid, melious, NearAI.

**Catalog hazard (resolved).** Live models.dev lists OpenCode's provider `api` as `https://opencode.ai/inference/openai/v1` with per-model mounts (`/inference/anthropic/v1`, `/inference/google/v1beta`, `/inference/systemone/v1`). With per-dialect endpoints (phase 1) the refreshed snapshot (phase 3) loads them all, and OpenCode requests now go to the `/inference/` mounts instead of `zen/v1`; the sweep is the check that Zen serves them.

**Eligibility and dialects.** models.dev: a model loads for text when untyped or `chat`-typed with tool use and text in and out, for decisions when `decision`-typed with text in; other types and deprecated models are left out. Decision models read their own npm table, `@ai-sdk/typesafe-ai` → SystemOne and `@ai-sdk/openai` → OpenAIDecisions, with no fallback dialect: the five decision models with only a provider-level package are skipped. llm_db: text as before; decisions from `execution.evaluate.family` (`typesafe_systemone` and `openrouter_decisions` → SystemOne, `openai_decisions` → OpenAIDecisions, `cloudflare_ai_run` skipped), so llm_db's `gpt-6-luna` arrives with both capabilities. `Source.build_model/1` takes `"dialects"`, a list keyed by each module's capability.

The refresh dropped 113 built-in models: 54 now deprecated, 52 gone from the catalog, and 5 left out by type (realtime `openai:gpt-realtime-2.1` and `google:gemini-3.1-flash-live-preview`, which only work over websockets; image-type `google:gemini-3.1-flash-lite-image` and OpenRouter's `google/gemini-3-pro-image` and `google/gemini-nano-banana-2.1`). NearAI's fixture model `zai-org/GLM-5.1-FP8` went; its fixtures replay on `z-ai/glm-5.3`.

## Design

### Model shape

Settled before phase 3. The model struct stays flat, and its capabilities are the keys of `dialects`: no `type` field, which would restate them and couldn't describe `gpt-6-luna` serving both. A capability is a kind of request (`:text`, `:decision`); a modality is a kind of content (`:text`, `:image`, `:pdf`), and `:text` is both, so the helpers name the capability: `Model.capabilities/1`, `Model.capability?/2` (renamed from phase 2's `supports?/2`, which a reader could take for a modality check) and `Model.dialect/2`. Modalities get no helpers. `input_modalities` and `output_modalities` stay: a decision's answers are structured text, and Gemini-style mixed output would need the output field back. `thinking` is a text feature (`false` on decision models), and tool use stays the floor for text models, enforced by the sources rather than a field: models without it aren't much use to anyone. Nesting per-capability data (`capabilities: %{text: %{dialect, thinking, input}}`) was rejected: catalogs give one record per model id, so it would mostly copy data.

### Surface API

`Omni.decide/3` mirrors `generate_text/3`: `Omni.decide(model, decision, opts)` where `decision` is a `%Omni.Decision{}` or the shorthand `{state, questions}`. Synchronous; there is nothing to stream.

- **`%Omni.Decision{}` is both request and result.** Built from `state` and `questions`, it flows through the dialect and the provider hook with `answers` and `usage` nil, and comes back filled, plus `model` and `raw` (the `{req, resp}` pair when `raw: true`). One struct means the hook, the response callback and the caller all see the same shape, and the result keeps the questions beside the answers.
- **State** is a string, a map, or a list of strings and maps: anything JSON-encodable. System One takes it natively; OpenAI gets a string as `input` and anything else as an `input_json` part. Content blocks, `%Context{}` and images are deferred with `box`.
- **Questions are a keyword list** of question structs: the atom key is the name, and the list keeps OpenAI's answer order. Structs follow the Content convention (match on struct, no type field): `Omni.Question.Predicate{instructions, criteria}`, `Omni.Question.Choice{instructions, choices}`, `Omni.Question.Score{instructions, levels}`. Choices and levels accept a bare list of names or name → description pairs; keys may be atoms or strings and come back as given. Constructors `Omni.Question.predicate/2`, `choice/2`, `score/2`, delegated from `Omni` beside `tool/1` and `message/1`. The yes/no primitive is `predicate` (OpenAI's name); System One's `noul` is an encoding detail.
- **Answers are a keyword list** aligned with the questions, so `answers[:name]` works and order survives: `Omni.Answer.Predicate{probability}`, `Omni.Answer.Choice{choice, probabilities, confidence}`, `Omni.Answer.Score{score, probabilities, confidence}`, `Omni.Answer.Refusal{}`. `probabilities` is a list of `{key, probability}` pairs in the caller's order with the caller's keys (System One's option strings and level indices are mapped back; its `legend` is dropped as redundant). Confidence is the provider's number, nil where the API gives none.
- **Validation** happens once at the boundary with a Peri schema: at least one question, non-empty instructions (a map or list is JSON-encoded for OpenAI), at least two choices or levels. Provider caps are left to the provider.
- **Capability errors** before any HTTP: `decide` on a model with no decision dialect returns `{:error, {:unsupported_capability, :decision}}`; `generate_text` on a decision-only model returns `{:error, {:unsupported_capability, :text}}`.
- **Options**: the universal config keys (`api_key`, `host`, `headers`, `plug`, `timeout`, `raw`) plus the dialect's own schema (`safety_identifier`, `prompt_cache_key` on OpenAI; none on System One).

### Encoding and answers

Settled before phase 2, from the API references:

- **Score levels start at 0 on both APIs**, so `Answer.Score.score` is the same scale everywhere.
- **Predicate criteria** are `predicate(instructions, criteria \\ nil)` with `[true: "...", false: "..."]`, either key optional. System One sends them as `criteria: {"true", "false"}`; OpenAI has no field and drops them.
- **Choices** go to System One as `criteria: {key: description | null}` (null: judged by the key) and to OpenAI as `choices: [{value, description?}]`, values always strings so `true` and `"true"` can't diverge.
- **Score levels** go to System One as a list of descriptions only, the key standing in for a missing one (its criteria carry no names); to OpenAI as `levels: [{label, description?}]`.
- **State**: a string is OpenAI's `input`; anything else (a map or a list) is one `input_json` part of a user message (`{type: "input_json", data: state}`), so a list is the same JSON array System One gets.
- **Instructions**: a map or list is JSON-encoded for OpenAI, whose instruction parts are text and images only.
- **Strict answers**: a missing answer, an answer for a question not asked, or one of the wrong type is `{:error, {:invalid_answer, name}}`; extra top-level fields are ignored. Choice and level keys must differ as strings.
- **Usage**: every catalogued decision model is priced per token, input only (output at 0), some with cache reads, so `%Usage{}` fits unchanged and `reasoning_tokens` stays out. `gpt-6-luna` carries its chat pricing (output $0.50/M), but OpenAI's documented decision response has 0 output tokens.
- **Model helpers**: `Model.dialect/2` (`{:ok, mod}` or `{:unsupported_capability, cap}`) and `Model.supports?/2` (renamed `capability?/2` in phase 3, beside `capabilities/1`). The Loader checks each model names its dialects under their own capability.
- **Pipeline**: `Request.send/4` (`req, model, decision, opts`) takes the decision, which the dialect needs to map answers back; cost computation is `Usage.price/2`, shared with `StreamingResponse`.

### Dialect behaviours

`Omni.Dialect` becomes the base: the registry, `compat/2`, and the callbacks that identify a wire format regardless of capability. Capability callbacks move to one behaviour per capability. A module implements exactly one capability behaviour (the names overlap, so it cannot implement two); a provider serving both capabilities lists two dialects, which `dialects: %{text: ..., decision: ...}` already models.

```elixir
defmodule Omni.Dialect do
  @callback auth() :: :bearer | {:header, String.t()} | :none
  @callback compat_schema() :: Peri.map_schema()
  # registry, get/1, get!/1, compat/2, capability/1 (reads the module's behaviours)
end

defmodule Omni.Dialect.Text do
  @callback option_schema() :: Peri.map_schema()
  @callback handle_path(Model.t(), opts :: map()) :: String.t()
  @callback handle_body(Model.t(), Context.t(), opts :: map()) :: map()
  @callback handle_event(event :: map(), Model.t()) :: [{atom(), term()}]
end

defmodule Omni.Dialect.Decision do
  @callback option_schema() :: Peri.map_schema()
  @callback handle_path(Model.t(), opts :: map()) :: String.t()
  @callback handle_body(Model.t(), Decision.t(), opts :: map()) :: map()
  @callback handle_response(body :: map(), Decision.t(), Model.t()) :: {:ok, Decision.t()} | {:error, term()}
end
```

`use Omni.Dialect, :text` and `use Omni.Dialect, :decision` set the base and capability behaviours; nothing more. The registry gains `"systemone"` → `Omni.Dialects.SystemOne` and `"openai_decisions"` → `Omni.Dialects.OpenAIDecisions`. The Loader validates each dialect against the behaviour of the capability it is used under.

Neither dialect ships a compat flag at first. Host quirks (option caps, required `instructions`, image encodings) become flags only when a built-in needs them.

### Provider endpoints

A provider can serve several dialects, each at its own URL. OpenCode's live catalog entry mounts `/inference/openai/v1`, `/inference/anthropic/v1`, `/inference/google/v1beta` and `/inference/systemone/v1`; ofox `/anthropic/v1` and `/gemini/v1beta`; Ollama serves chat at `/api/chat` and System One at `/v1/systemone`. Some put a dialect on another host altogether: freemodel serves Anthropic from `cc.freemodel.dev/v1` and Completions from `api.freemodel.dev/v1`, and Alibaba's decision host is per workspace. So each dialect a provider serves gets an endpoint holding its own whole base URL, and the request URL is one join:

```
endpoint.base_url <> dialect.handle_path(model, opts)
```

The call-site `host:` option, when given, replaces the origin of `endpoint.base_url` first. A trailing slash on the base URL is trimmed, as today.

```elixir
%Omni.Provider{
  id: :opencode,
  name: "OpenCode Zen",
  api_key: {:system, "OPENCODE_API_KEY"},
  auth: :dialect,
  headers: %{},
  module: Omni.Providers.OpenCode,
  dialects: %{
    Omni.Dialects.OpenAICompletions => %Omni.Provider.Endpoint{
      base_url: "https://opencode.ai/inference/openai/v1",
      compat: %{thinking_replay_format: :reasoning_content}
    },
    Omni.Dialects.OpenAIResponses => %Omni.Provider.Endpoint{base_url: "https://opencode.ai/inference/openai/v1"},
    Omni.Dialects.AnthropicMessages => %Omni.Provider.Endpoint{base_url: "https://opencode.ai/inference/anthropic/v1"},
    Omni.Dialects.GoogleGemini => %Omni.Provider.Endpoint{base_url: "https://opencode.ai/inference/google/v1beta"},
    Omni.Dialects.SystemOne => %Omni.Provider.Endpoint{base_url: "https://opencode.ai/inference/systemone/v1"}
  }
}
```

- **The endpoint is a whole URL and its deviations**: `base_url` and `compat`. `base_url` means what every SDK and API doc means by it: the full URL, version segment included (`https://api.together.ai/v1`). The provider has no `base_url`, and its `compat` field and capability-keyed `dialects: %{text: [mods]}` map go; `Omni.Dialect.capability/1` answers the Loader's questions from the module's behaviours. `%Model{}` is unchanged: `dialects: %{text: Mod, decision: Mod}`, plus `Model.dialect/2` and `Model.capability?/2`.
- **Auth, headers and the API key stay on the provider.** Nobody configures auth per dialect; what varies per dialect is the resolution of `:dialect` to the home scheme, which the request does as now. Headers users set today are per host. If a gateway ever needs either per dialect, the field joins the endpoint and overrides the provider's. A provider is one account, and a different key means a different provider id.
- **`host` moves every endpoint.** It is an origin only (`scheme://host[:port]`): a value with a path raises at load and is `{:error, {:invalid_host, host}}` at the call site, since a `host:` that took a path would be a base URL by another name. It replaces the scheme, host and port of each endpoint URL and keeps the path: `ollama: [host: "http://gpu:11434"]` sends chat to `http://gpu:11434/api/chat` and System One to `http://gpu:11434/v1/systemone`. It is the one knob for the common moves (another box, a region, a proxy on the same paths, Bypass in tests) and fills catalog URLs templated only in the origin (`https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1`, `${NEON_AI_GATEWAY_BASE_URL}/v1`, Snowflake, both Azure mounts). For a template with no scheme the origin is the leading `${VAR}`; Neon's variable is a bare branch host, so `host:` fills both its endpoints. The rewrite works on whole URLs, once: nothing is stored in pieces or reassembled per request.
- **Where URLs are set**, each level doing one thing:

  | Where | Sets | When |
  |---|---|---|
  | `dialects: %{Mod => [base_url: url]}` | one endpoint's whole URL | load |
  | provider `host:` (app config) | the origin of every endpoint URL that came from the source or the module | load |
  | call-site `host:` | the origin of this request's URL | request |

  An endpoint URL written in app config is used as written; provider `host:` doesn't touch it (Alibaba: `host:` picks the chat region, an explicit workspace URL for System One stays put). The call-site `host:` overrides everything. There is no provider-level `base_url` and no call-site `base_url`: every case found fits `host:` or is clearer per endpoint. The one loss is changing a path for a single request, for which no use case was found; a path-changing gateway in front of a built-in (Cloudflare AI Gateway) is an endpoint URL in config.
- **Config.** Provider keys are `name`, `host`, `api_key`, `auth`, `headers`, `module`, `models`, `source` and `dialects`; module `config/0` takes `name`, `api_key`, `auth`, `headers` and `dialects`. Everything about an endpoint goes under its dialect: `dialects: %{Module => [base_url: ..., compat: [...]]}`. A module key with `[]` declares that the provider serves the dialect; it then needs a URL from some layer. `compat: [like: :id]` under a dialect copies that dialect's flags from a built-in. The v1 forms raise at boot with a migration message: provider-level `base_url:` (suggesting `host:` with the origin when the path matches the endpoint's, otherwise the `dialects:` form naming the module), flat `compat:`, keyed `compat: %{Module => ...}`, and `dialects: %{text: Module}`.
- **Merge rule.** Layers merge in the existing order, source ← module `config/0` ← app config, each stating only its deltas. Provider fields replace, `headers` merge by key. `dialects` merge by module, then by field: `base_url` replaces, `compat` merges by flag. The Loader applies `host` after merging. There is no check for endpoints no model uses.
- **Sources write whole URLs and split nothing.** A dialect's endpoint URL is the URL of its models: a model's own URL (models.dev `provider.api`, llm_db `base_url`) when it has one, otherwise the catalog's provider URL. Another host is fine. When models of one dialect disagree, the first by id wins and the rest are skipped with a warning (in the bundled catalog only google-vertex, whose URLs are templated anyway). Templated URLs are kept verbatim, in both forms (`${VAR}` from models.dev, `{var}` from llm_db), so `host:` can fill them; the code that drops them goes. A catalog provider URL with no known dialect has no endpoint to land on and is dropped: declaring the dialect means writing its `base_url` too (about 80 llm_db providers, and merge-gateway on models.dev). This replaces `check_mount`. Freemodel's Completions models and Cohere's one Completions model, skipped today, load.
- **Model capabilities come from model data, and nothing is filled in.** A model's dialects come from its catalog data or its provider module's `models/2`; there is no default dialect, per provider or per capability. If the source can't tell a model's dialect, it skips it: that is the source's job. A catalog model with no dialect, or whose dialect has no endpoint, is skipped with a warning; a config model with either raises at load (a mistake in config, not a gap in data). Checked before deciding: built-ins on models.dev lose nothing; models.dev's 968 dialect-less models are on 17 providers whose own SDKs need a module or a new dialect anyway; llm_db's are ones it marks `catalog_only` (llm_db applies per-operation provider defaults where it has curated them and marks the rest; req_llm refuses those). So the llm_db source skips `catalog_only` models and models with no wire or npm signal, and its hardcoded OpenCode Completions fallback goes. Ollama's `models/2` stamps OllamaChat on config models with none. A provider's models must each have at least one capability; "must have text" goes.
- **Config models merge over catalog models.** A `models:` entry whose id the catalog has is merged over it field by field (`dialects` by capability), so it corrects catalog data without restating it; an entry with a new id is a new model and names its dialect. A module's `models/2` runs after the merge, so a module that overrides catalog dialects (OllamaCloud, xAI) also overrides one set in config.
- **Missing URLs fail at request time.** Nothing is checked at load, and today's boot raise for a provider with no `base_url` goes. A model whose dialect has no endpoint returns `{:error, {:no_endpoint, dialect}}` (models built by hand; a future `put_dialect` raises instead). An endpoint with no URL, or one still holding a placeholder after `host`, returns `{:error, {:no_base_url, dialect}}`.
- **Built-in modules** write each endpoint's URL under its dialect: `dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.together.ai/v1", compat: [...]]}`. OpenCode's module stops hardcoding `zen/v1` and lets the catalog URLs stand. Ollama: `auth: :none`, OllamaChat at `http://localhost:11434` and System One at `http://localhost:11434/v1`. Ollama Cloud adds OllamaChat at `https://ollama.com`; the catalog's Completions endpoint at `https://ollama.com/v1` stays, unused. Alibaba's region table becomes a table of `host:` values, since regions share `/compatible-mode/v1`; its decision endpoint, when catalog data lands, is a templated per-workspace URL the user sets under `dialects:`.

*History: the first attempt (branch `v2-decisions-api`, commit `d8fd552`) split the URL into a provider `base_url` holding the shared host and a per-endpoint `path_prefix`. It made `base_url` mean the host (so `openai: [base_url: "http://localhost:4000/v1"]` went to `/v1/v1/responses`), left it holding the whole URL where no endpoint could take the path, needed about 60 lines in sources to take catalog URLs apart, couldn't represent another host, and had three joins. Its endpoint table, config shape under `dialects:`, merging and `no_endpoint` error are kept; its Loader fill is not.*

### Request pipeline

| Piece | Change |
|---|---|
| `Request.build/3` | Takes `%Context{}` or `%Decision{}`; the struct picks the capability, hence the dialect and the endpoint. `into: :self` only for text. URL is `endpoint.base_url` (origin replaced by a call-site `host:`) `<> dialect.handle_path/2`; `{:no_endpoint, dialect}` and `{:no_base_url, dialect}` errors before any HTTP |
| `Request.validate/2` | Universal config keys split from text inference keys; each capability merges its own dialect schema. Provider `api_key` and `headers` merge with call-site opts as today; `host` replaces `base_url` as a call-site key, and the URL itself is read from the endpoint, not merged as an option |
| `Request.send/3` | New sibling of `stream/3`: request, `check_status`, JSON decode, `dialect.handle_response/3`, cost stamped on usage |
| `Omni.Usage` | Cost computation moves out of `StreamingResponse` into `Usage` so both paths share it; gains `reasoning_tokens` from OpenAI's details (also a backlog item) |
| Provider hooks | `modify_body(body, model, %Context{} \| %Decision{}, opts)`: the struct is the discriminator, so no capability atom. `modify_request/3` unchanged |
| `Omni.Loop`, `StreamingResponse`, parsers | Untouched |

## Verification and fixtures

Settled in a pre-plan pass on 2026-11-04, after kicking the tyres on TypeSafe and local Ollama models.

- **Probabilities pass through as the host sends them.** TypeSafe rounds to two decimals on the wire, Ollama sends full floats; Omni rounds neither, since rounding loses ranking at the tails and stops probabilities summing to 1. It only makes them floats: Ollama sends `1` and `0` as JSON integers, which `Float.round/2` rejects.
- **Scenarios**: `decision` (a string state; a predicate with both criteria, a choice with one undescribed option, a score with bare level keys) and `decision_json` (a map state and map instructions, the OpenAI `input_json` and JSON-encoded instruction paths). Defaults come from the model's capabilities, added together: text brings `text`, `thinking`, `tool_use`, `structured_output`; decision brings both decision scenarios; `gpt-6-luna` runs all six.
- **A pass is shape plus meaning.** Every answer present and well formed (floats from 0 to 1, keyed by the question's options in order, no refusal, input tokens counted), and the clear-cut questions answered as expected: the predicate over 0.5, the obvious choice. The score is checked for shape only. A small model can be strict on fuzzy questions (d3 2B rejected a one-letter name typo outright, in prose and JSON alike), so the questions are unambiguous. Baselines assert the same rule (`Scenarios.check_decision/2`).
- **Fixtures** follow the testing tiers: a `decision` and a `decision_json` baseline (with target) for each built-in with decision models, TypeSafe `jev-1.14.0`, OpenAI `gpt-6-luna`, OpenRouter `typesafe/jev-1.14`, OpenCode `jev-1.13-free`, Ollama `pplx-decider-flash:4b-nvfp4`. `decision_json` is recorded too: it shows the host accepted the JSON form. The dialect tier holds only OpenAI's cache read (two turns over a 7k-token state). `Capture.record/4` and `replay/4` take a `%Decision{}` and write raw `.json`.
- **Left out**: a refusal capture (OpenAI documents no trigger; the unit test covers it) and synthetic error fixtures (HTTP errors take the shared `check_status`, already unit-tested). NearAI has no key and stays unverified.
- **Sweep**: the decision models above, plus OpenRouter's `openai/gpt-6-luna-decisions` (System One in front of OpenAI's API).
- Capture and verify are run by the maintainer only, as always; TypeSafe and local Ollama are free.

## Phases

1. **Provider endpoints** (text only). `Omni.Provider.Endpoint{base_url, compat}`; the provider loses `base_url` and `compat`; one-join URL; `host` in app config (applied by the Loader after merging) and at the call site, replacing call-site `base_url`; Loader merge and config migration messages (provider `base_url:`, `compat:`, `dialects: %{text: ...}`); request-time `no_endpoint` and `no_base_url` errors, and the boot `base_url` raise goes; `Omni.Dialect.capability/1`; sources write whole endpoint URLs and keep templates (replacing `check_mount` and the template-dropping code); built-in modules write endpoint URLs, OpenCode's stops hardcoding `zen/v1`; no dialect fill, catalog models skipped and config models raising without one; config models merge by id; the sweep's Ollama reachability check reads the endpoint URL; docs for `Omni.Provider`, CLAUDE.md, design.md, README, v2-changes and roadmap. Exit: `mix precommit` green, built-in model sets and integration request targets unchanged on the bundled snapshot, zenmux (+22), ofox (+19), freemodel (+4) and cohere (its one Completions model) gain their off-mount models, llm_db built-ins lose only models llm_db marks `catalog_only` or gives no text execution (opencode 76, nearai 25, alibaba 2 realtime, google 1 live, openrouter 4: two image models and two `auto` routers), a sweep over the existing matrix passes. *Landed 2026-11-03; the sweep is the maintainer's to run.*
2. **Core decisions.** `Omni.Dialect` split with `use`, `Omni.Dialect.Text` and `.Decision`, `Omni.Decision`, `Omni.Question.*`, `Omni.Answer.*`, Peri schema, `Request.build/validate` split, `Request.send/4`, `Usage.price/2`, `Omni.Dialects.SystemOne` and `OpenAIDecisions`, `Omni.decide/3`, capability errors, `Model.dialect/2` and `supports?/2`, the Loader's capability check. Unit tests on hand-written bodies. *Landed 2026-11-03.*
3. **Catalog and providers.** xAI and Ollama Cloud's `models/2` re-stamp only text models (and config models with no dialect). `mix omni.snapshot` and live mode fetch `?type=chat,decision`; type-aware eligibility (decision models need no `tool_call`; other types stay out, also in the source, for old live caches); an explicit decision npm table; LLMDB reads `execution.evaluate.family`; OpenAI stamps `gpt-6-luna` and gains a Decisions endpoint; OpenRouter declares its System One endpoint; new TypeSafe module; Ollama's System One endpoint (no `type:` shorthand); `Model.capability?/2` and `capabilities/1`; golden tests; snapshot refresh. *Landed 2026-11-03.* Exit: decision models on OpenRouter (33), OpenCode (2), NearAI (2), TypeSafe (4) and `openai:gpt-6-luna` (both capabilities), each building a request to the URL in the host table; text model sets changed only by catalog churn and the five type-excluded models.
4. **Live verification and fixtures.** Integer answers as floats; `decision` and `decision_json` scenarios with capability-driven defaults and a shape-plus-meaning pass; `.json` capture; decision baselines for TypeSafe, OpenAI, OpenRouter, OpenCode and Ollama; OpenAI's cache case in the dialect tier; sweep entries. See Verification and fixtures.
5. **Docs.** `design.md` (Providers → Endpoints, Dialects → behaviours, a Decisions section), moduledocs, README, `v2-changes.md` entries for endpoints and decisions, roadmap.

## Deferred

- Images and `box`: TypeSafe `assets` with the `TypeSafe-Danger-Zone-Images` header, Ollama and Venice `images`, OpenRouter `image_url` parts, OpenAI `input_image`. Content blocks or `%Context{}` as state come with it.
- Confidence normalisation from probabilities; the warning mechanism for silently dropped fields (predicate criteria on OpenAI, descriptions on some hosts).
- Per-dialect `auth` or `headers` on the endpoint, overriding the provider's; nothing needs either yet.
- Upstream: a TypeSafe entry and `type: decision` markers for Ollama Cloud, Alibaba and Venice in models.dev; a way to express that `gpt-6-luna` serves two APIs.

## Sources

- TypeSafe: [System One](https://docs.typesafe.ai/concepts/system-one.md), [API reference](https://docs.typesafe.ai/api.md), [OpenAPI](https://api.typesafe.ai/openapi.json), [confidence](https://docs.typesafe.ai/confidence.md)
- OpenAI: [Decisions guide](https://developers.openai.com/api/docs/guides/decisions), [create reference](https://developers.openai.com/api/reference/resources/decisions/methods/create/index.md)
- Ollama: [System One](https://docs.ollama.com/api/systemone)
- Alibaba: [Decision model API](https://www.alibabacloud.com/help/en/model-studio/decision-model-api)
- Venice: [Decisions create](https://docs.venice.ai/api-reference/endpoint/decisions/create.md)
- models.dev: `https://models.dev/api.json?type=all`; llm_db 2026.10.6 `execution.evaluate`
- Prior art: req_llm `ReqLLM.evaluate/4`, Vercel `experimental_decide`, LangChain `OpenAIDecisions`, pydantic-ai, LiteLLM
