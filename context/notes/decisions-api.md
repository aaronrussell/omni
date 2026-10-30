# Decisions API — design (pass two)

*2026-10-30. The agreed plan, replacing the 2026-10-09 brainstorm. Everything here was settled in discussion; the phases at the end are the order of work. The research behind it (wire formats, hosts, catalog) is summarised rather than reproduced.*

## What we are building

A second capability beside text generation: send one shared input plus a set of independent, typed questions, and get back calibrated probabilities instead of prose. No streaming, no tools, no multi-turn. Two wire formats cover every known host: TypeSafe's **System One** (the de facto open standard, served by TypeSafe, Ollama, OpenRouter, OpenCode Zen, Alibaba, Venice, Cloudflare, Liquid and others) and **OpenAI Decisions** (`gpt-6-luna` only, also proxied by Vercel). Hosts differ in paths, image encoding, option caps and confidence formulas, none of which needs a third dialect: variation is compat flags and tolerant parsing.

The work also restructures the provider so that each dialect it serves has its own endpoint (a path prefix on the provider's host, plus compat), which fixes the "per-model base URL" backlog item and is needed before OpenCode's catalog data can be refreshed.

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

Live models.dev with `?type=all` (checked 2026-10-30) carries 69 decision models, all `type: "decision"`, all `tool_call: false`, 48 marked System One by a model-level npm of `@ai-sdk/typesafe-ai`. Of Omni's built-ins only OpenRouter (34) and OpenCode (`jev-1.13`, `jev-1.13-free`) have any. `gpt-6-luna` under `openai` is a plain chat model, since `type` is a single exclusive string. TypeSafe is not a models.dev provider at all (llm_db has it: `https://api.typesafe.ai`, `TYPESAFE_API_KEY`, `jev-1.13.0`, `jev-latest`, `jev-preview`). Ollama Cloud, Alibaba and Venice serve System One but carry no decision models in either catalog.

**Rule: stamp, don't invent.** A built-in module may add a capability to a model the catalog has (OpenAI stamps the decision dialect onto `gpt-6-luna`), and may supply models only for a provider the catalog has no entry for (TypeSafe, like local Ollama). It never adds models to a provider the catalog knows. So Ollama Cloud, Alibaba and Venice wait for catalog data; the paths are documented below for when it lands.

**Hosts in scope**, all with keys to verify:

| Host | Dialect | Mount | Notes |
|---|---|---|---|
| TypeSafe (new) | System One | `https://api.typesafe.ai` + `/v1` | New `Omni.Providers.TypeSafe`. Models from llm_db when that source is used; otherwise hardcoded in `models/2` when the catalog returns none. System One's home API, so dialect-tier fixtures record here |
| OpenAI | OpenAI Decisions | `https://api.openai.com` + `/v1` | `models/2` stamps `decision: Omni.Dialects.OpenAIDecisions` on `gpt-6-luna`. $0.10/M input, cached $0.01 |
| OpenRouter | System One | `https://openrouter.ai` + `/api/v1` (alias `/systemone`) | 34 catalog models, same prefix as the text dialects. Extra response fields ignored |
| OpenCode | System One | `https://opencode.ai` + `/inference/systemone/v1` | Catalog mount, derived by the source. The module stops hardcoding `zen/v1` |
| Ollama | System One | `http://localhost:11434` + `/v1` | Config-listed models, `type: :decision` sugar. Chat is at `/api/chat` with an empty prefix. Images later |

Held for catalog data: Ollama Cloud (`https://ollama.com/v1/systemone`, `clef:cloud`), Alibaba (`https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/systemone`, `decision-model-preview`, 16 questions), Venice (`/api/v1/systemone` alias, `jev-latest`, `clef`, `clef-api`). Not built-ins: Cloudflare, Vercel, nano-gpt, vivgrid, melious, NearAI.

**Catalog hazard.** Live models.dev now lists OpenCode's provider `api` as `https://opencode.ai/inference/openai/v1` with per-model mounts (`/inference/anthropic/v1` ×24, `/inference/google/v1beta` ×9, `/inference/systemone/v1` ×2). The current source skips models whose mount differs from the provider's, so a snapshot refresh would drop 33 OpenCode models. Per-dialect endpoints (phase 1) must land before the snapshot is refreshed (phase 3).

## Design

### Surface API

`Omni.decide/3` mirrors `generate_text/3`: `Omni.decide(model, decision, opts)` where `decision` is a `%Omni.Decision{}` or the shorthand `{state, questions}`. Synchronous; there is nothing to stream.

- **`%Omni.Decision{}` is both request and result.** Built from `state` and `questions`, it flows through the dialect and the provider hook with `answers` and `usage` nil, and comes back filled, plus `model` and `raw` (the `{req, resp}` pair when `raw: true`). One struct means the hook, the response callback and the caller all see the same shape, and the result keeps the questions beside the answers.
- **State** is a string, a map, or a list of strings and maps: anything JSON-encodable. System One takes it natively; OpenAI gets a string as `input` and anything else as an `input_json` part. Content blocks, `%Context{}` and images are deferred with `box`.
- **Questions are a keyword list** of question structs: the atom key is the name, and the list keeps OpenAI's answer order. Structs follow the Content convention (match on struct, no type field): `Omni.Question.Predicate{instructions, criteria}`, `Omni.Question.Choice{instructions, choices}`, `Omni.Question.Score{instructions, levels}`. Choices and levels accept a bare list of names or name → description pairs; keys may be atoms or strings and come back as given. Constructors `Omni.Question.predicate/2`, `choice/2`, `score/2`, delegated from `Omni` beside `tool/1` and `message/1`. The yes/no primitive is `predicate` (OpenAI's name); System One's `noul` is an encoding detail.
- **Answers are a keyword list** aligned with the questions, so `answers[:name]` works and order survives: `Omni.Answer.Predicate{probability}`, `Omni.Answer.Choice{choice, probabilities, confidence}`, `Omni.Answer.Score{score, probabilities, confidence}`, `Omni.Answer.Refusal{}`. `probabilities` is a list of `{key, probability}` pairs in the caller's order with the caller's keys (System One's option strings and level indices are mapped back; its `legend` is dropped as redundant). Confidence is the provider's number, nil where the API gives none.
- **Validation** happens once at the boundary with a Peri schema: at least one question, non-empty instructions (a map or list is JSON-encoded for OpenAI), at least two choices or levels. Provider caps are left to the provider.
- **Capability errors** before any HTTP: `decide` on a model with no decision dialect returns `{:error, {:unsupported_capability, :decision}}`; `generate_text` on a decision-only model returns `{:error, {:unsupported_capability, :text}}`.
- **Options**: the universal config keys (`api_key`, `base_url`, `headers`, `plug`, `timeout`, `raw`) plus the dialect's own schema (`safety_identifier`, `prompt_cache_key` on OpenAI; none on System One).

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

Every known split in a gateway's lineup is by dialect and by path, never by host: OpenCode mounts `/inference/openai/v1`, `/inference/anthropic/v1`, `/inference/google/v1beta` and `/inference/systemone/v1`; ofox `/anthropic/v1` and `/gemini/v1beta`; Cloudflare `/ai/v1` and `/ai/run`. So a provider is one host with one mount per dialect, and the struct says so. The request URL is three parts:

```
provider.base_url <> endpoint.path_prefix <> dialect.handle_path(model, opts)
```

```elixir
%Omni.Provider{
  id: :opencode,
  name: "OpenCode Zen",
  base_url: "https://opencode.ai",
  api_key: {:system, "OPENCODE_API_KEY"},
  auth: :dialect,
  headers: %{},
  module: Omni.Providers.OpenCode,
  dialects: %{
    Omni.Dialects.OpenAICompletions => %Omni.Provider.Endpoint{path_prefix: "/inference/openai/v1", compat: %{max_tokens_field: "max_tokens"}},
    Omni.Dialects.AnthropicMessages => %Omni.Provider.Endpoint{path_prefix: "/inference/anthropic/v1", compat: %{}},
    Omni.Dialects.SystemOne => %Omni.Provider.Endpoint{path_prefix: "/inference/systemone/v1", compat: %{}}
  }
}
```

- **`base_url` is the root every endpoint shares**, scheme and host at least. For catalog providers the source puts the version segment in the endpoint prefix; a custom single-dialect provider may fold it into `base_url` and leave the prefix empty (`gpu_box: [base_url: "http://gpu-box:8000/v1", dialects: %{Omni.Dialects.OpenAICompletions => []}]`). This replaces the v1 rule "base_url includes the version segment". A provider is one origin; a host that serves a dialect from another origin (Alibaba's per-workspace decision host) is a second provider id.
- **The endpoint is the mount and its deviations**: `path_prefix` (default `""`) and `compat`. The `compat` field and the capability-keyed `dialects: %{text: [mods]}` map leave the provider; `Omni.Dialect.capability/1` answers the Loader's questions from the module's behaviours. `%Model{}` is unchanged: `dialects: %{text: Mod, decision: Mod}`, plus `Model.dialect/2` and `Model.supports?/2`.
- **Auth and headers stay on the provider.** Nobody configures auth per dialect; what varies per dialect is the resolution of `:dialect` to the home scheme, which the request does as now. Headers users set today are per host. If a gateway ever needs either per dialect, the field joins the endpoint and overrides the provider's. **The API key stays on the provider**: a provider is one account, and a different key means a different provider id.
- **Call-site `base_url:` replaces the provider's `base_url`** and keeps the endpoint prefix, so the key means the same thing everywhere: the shared root. A mirror or test host is the use case; a per-request mount change is not one. `api_key:` and `headers:` at the call site work as today.
- **Config.** Provider keys are `name`, `base_url`, `api_key`, `auth`, `headers`, `module`, `models`, `source` and `dialects`. Everything about an endpoint goes under its dialect: `dialects: %{Module => [path_prefix: ..., compat: [...]]}`; a module key with `[]` declares that the provider serves the dialect. `compat: [like: :id]` under a dialect copies that dialect's flags from a built-in. The v1 forms, flat `compat:`, keyed `compat: %{Module => ...}` and `dialects: %{text: Module}`, go, and the boot-time migration message names them.
- **Merge rule.** Layers merge in the existing order, source ← module `config/0` ← app config, each stating only its deltas. Provider fields replace, `headers` merge by key. `dialects` merge by module, then by field, with `compat` merging by flag and `path_prefix` replacing. Configuring one flag on one endpoint touches nothing else. A module key that no layer declares and no model speaks is a config error with a message, as unknown compat keys are today.
- **Sources derive the table.** Parse the catalog's provider `api` into origin and path: origin is `base_url`, path is the prefix of the provider's own dialect. A model-level mount on the same origin gives its dialect a prefix (its models must agree, or the odd one out is skipped with a warning); a mount on another origin is skipped with a warning, as now. This replaces `check_mount`. The provider-level npm hint becomes an endpoint entry with an empty prefix.
- **Model capabilities come from model data.** The only fill is text: a model with no dialect at all gets the provider's only text endpoint, or is skipped with a warning when there are several or none. Decision dialects are never filled, since filling would mark every chat model on a System One host as a decision model. A provider's models must each have at least one capability; "must have text" goes.
- **Built-in modules.** Single-dialect modules write `base_url` as the origin and the prefix under the dialect (`base_url: "https://api.together.ai", dialects: %{Omni.Dialects.OpenAICompletions => [path_prefix: "/v1", compat: [...]]}`). OpenCode's module stops hardcoding `zen/v1` and lets the catalog mounts stand. Ollama's module sets `base_url: "http://localhost:11434"`, `auth: :none`, OllamaChat with an empty prefix (its path is `/api/chat`) and SystemOne with `/v1`; moving it to another host is one line. Alibaba's region table becomes a `base_url` change too, since regions differ by host and share `/compatible-mode/v1`.

### Request pipeline

| Piece | Change |
|---|---|
| `Request.build/3` | Takes `%Context{}` or `%Decision{}`; the struct picks the capability, hence the dialect and the endpoint. `into: :self` only for text. URL is `provider.base_url <> endpoint.path_prefix <> dialect.handle_path/2` |
| `Request.validate/2` | Universal config keys split from text inference keys; each capability merges its own dialect schema. Provider `base_url`, `api_key` and `headers` merge with call-site opts as today |
| `Request.send/3` | New sibling of `stream/3`: request, `check_status`, JSON decode, `dialect.handle_response/3`, cost stamped on usage |
| `Omni.Usage` | Cost computation moves out of `StreamingResponse` into `Usage` so both paths share it; gains `reasoning_tokens` from OpenAI's details (also a backlog item) |
| Provider hooks | `modify_body(body, model, %Context{} \| %Decision{}, opts)`: the struct is the discriminator, so no capability atom. `modify_request/3` unchanged |
| `Omni.Loop`, `StreamingResponse`, parsers | Untouched |

## Verification and fixtures

- **Scenarios**: `decision` (string state, one predicate, one choice, one score) and `decision_json` (map state). A model whose dialects include `:decision` and not `:text` defaults to those; a model with both runs the text defaults plus `decision`. The sweep matrix adds one decision model per host.
- **Fixtures**: `Capture.record/4` and `replay/4` take a `%Decision{}` and write `.json` fixtures served as `application/json` without streaming. Dialect tier: System One recorded from TypeSafe, OpenAI Decisions from OpenAI, each covering the three answer types plus a refusal where the API produces one; synthetic fixtures for error bodies and OpenAI's refusal if not. Provider tier: a `decision` baseline for OpenRouter, OpenCode and Ollama asserting the request target and shape.
- Capture and verify are run by the maintainer only, as always.

## Phases

1. **Provider endpoints** (text only, no behaviour change). `Omni.Provider.Endpoint`, three-part URL, Loader merge and config migration messages, `Omni.Dialect.capability/1`, sources split origin from prefix and derive mounts, OpenCode module and its target assertions, docs for `Omni.Provider`. Exit: `mix precommit` green, integration targets unchanged, a sweep over the existing matrix passes.
2. **Core decisions.** `Omni.Dialect` split with `use`, `Omni.Dialect.Text` and `.Decision`, `Omni.Decision`, `Omni.Question.*`, `Omni.Answer.*`, Peri schema, `Request.build/validate` split, `Request.send/3`, `Usage` cost extraction, `Omni.Dialects.SystemOne` and `OpenAIDecisions`, `Omni.decide/3`, capability errors. Unit tests on hand-written bodies.
3. **Catalog and providers.** `mix omni.snapshot` and live mode fetch `?type=all`; type-aware eligibility (decision models need no `tool_call`; other non-text types stay out); decision dialect inference (`type: decision` ⇒ systemone unless the model npm is `@ai-sdk/openai`); LLMDB reads `execution.evaluate.family`; OpenAI stamps `gpt-6-luna`; new TypeSafe module; Ollama `type: :decision` sugar and System One endpoint; golden test. Snapshot refresh happens here, after phase 1.
4. **Live verification and fixtures.** Scenarios, `.json` capture, dialect fixtures from TypeSafe and OpenAI, provider baselines for OpenRouter, OpenCode and Ollama, sweep entries.
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
