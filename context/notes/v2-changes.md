# v2 changes — running log

*Started 2026-10-16. A working record of every user-facing change in v2.0.0, kept as detailed as needed. Each phase of v2 work adds to it as it lands. Before release it becomes the source for two things: an "Upgrading to v2" extras page in the docs (where the snippet-level detail lives), and a concise `CHANGELOG.md` entry covering the broad areas of change. Organised by area, not by phase, so it reads as a whole.*

## Configuration

**Provider config moved under `:providers`, keyed by id.** *(phase 1)*

```elixir
# v1
config :omni, Omni.Providers.Anthropic, api_key: {:system, "MY_KEY"}

# v2
config :omni, :providers, anthropic: [api_key: {:system, "MY_KEY"}]
```

The v1 form raises at boot with a migration message naming the id.

**`providers:` in `config :omni, :models` takes ids, not modules.** *(phase 1)* `providers: [:anthropic, :openai]`; `:builtins` still names all built-ins and may appear in the list. A module in the list raises, suggesting the id. Configuring a provider never enables it.

**URLs live on per-dialect endpoints; `host:` moves them.** *(phase 1, endpoints)* A provider has no `base_url`. Each dialect it serves has an endpoint with its own whole URL, version segment included, and its own compat flags, set under `dialects:`. A request goes to the endpoint URL plus the dialect's resource path (`/chat/completions`). `host:` (an origin: scheme, host and port, no path) replaces the origin of every endpoint URL from the catalog and the provider module and keeps paths; URLs written in app config are used as written. Local Ollama is still `http://localhost:11434`, path `/api/chat`.

```elixir
# v1
config :omni, Omni.Providers.Ollama, base_url: "http://gpu-box:11434"
config :omni, :providers, gpu_box: [base_url: "http://gpu-box:8000/v1", dialects: %{text: Omni.Dialects.OpenAICompletions}]

# v2
config :omni, :providers,
  ollama: [host: "http://gpu-box:11434"],
  gpu_box: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]}]
```

Provider-level `base_url:` raises at boot, suggesting `host:` when only the origin differs and the endpoint form otherwise; so does `base_url:` in a module's `config/0`. The `base_url:` request option is gone too: pass `host:` (an origin) to move one request. A missing endpoint URL is no longer a boot error: a request returns `{:error, {:no_base_url, dialect}}` (also for a URL still holding a catalog placeholder), and a model whose dialect has no endpoint `{:error, {:no_endpoint, dialect}}`.

**`auth_header:` is replaced by `auth:`.** *(phase 1)* `auth_header: "x-api-key"` becomes `auth: {:header, "x-api-key"}`. Values: `:bearer`, `{:header, name}`, `:none`, `:dialect` (the default — the scheme of the dialect's home API). Using `auth_header:` raises with a hint.

**Per-provider source override moved.** *(phase 1)* `config :omni, Omni.Providers.OpenAI, source: ...` becomes `config :omni, :providers, openai: [source: ...]`.

**Compat flags, set per endpoint.** *(phase 2; moved under `dialects:` in endpoints)* Compat flags describe how a provider deviates from a dialect's home API (see Dialects). They go on the endpoint of the dialect they apply to; `like: :zai` copies a built-in's flags for the same dialect, with your own layered over them. Flags merge one at a time across layers. Unknown flags and bad values are boot errors. A top-level `compat:` raises with a migration message.

```elixir
config :omni, :providers,
  fireworks_ai: [dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :zai, attachment_format: :file]]}],
  opencode: [dialects: %{Omni.Dialects.OpenAICompletions => [compat: [max_tokens_field: "max_tokens"]]}]
```

**Unknown keys are errors.** *(phase 1)* Per-provider keys: `name, host, api_key, auth, headers, dialects, module, models, source`; a module's `config/0` takes `name, api_key, auth, headers, dialects`; an endpoint takes `base_url, compat`. `:models` keys: `providers, source, filter, transform`. Entries for providers that aren't loaded are still validated.

**The legacy v1.x `:providers` list** (`config :omni, :providers, [:anthropic, :openai]`) still raises, with an updated message.

## Providers

**Providers are data.** *(phase 1)* A provider is an `%Omni.Provider{}` struct (`id, name, api_key, auth, headers, dialects, module`), assembled at load from source catalog data, then an optional provider module's `config/0`, then app config. `dialects` maps each dialect module to an `%Omni.Provider.Endpoint{base_url, compat}`. Values replace; `headers` merge by key, `dialects` by module and then by field, `models` by id.

**Any catalog provider loads by id.** *(phase 1)* For example `providers: [:builtins, :togetherai]`. They speak their dialects plain, with no quirks. Where the catalog lacks a URL, set the endpoint's: `togetherai: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.together.xyz/v1"]}]`.

**Gateways serve each dialect from its own URL.** *(endpoints)* Sources give each dialect the URL of its models (a model's own catalog URL, else the provider's), on another path or another host, and keep templated URLs for `host:` to fill. Models the catalog mounts elsewhere now load instead of being skipped: zenmux and ofox gain their Anthropic and Gemini models, freemodel its Completions models (on `api.freemodel.dev`), cohere its one Completions model. When models of one dialect disagree on the URL, the first by id wins and the rest are skipped with a warning.

**Dialects come from model data only.** *(endpoints)* Nothing fills in a missing dialect. A catalog model whose package maps to no dialect Omni speaks (including through its provider's package), or whose dialect has no endpoint, is skipped with a warning. A config model with no dialect, or a dialect with no endpoint, raises at load, unless the provider module's `models/2` stamps one (Ollama stamps `OllamaChat`). `Omni.Model.new/1` no longer fills dialects from the provider, and `Omni.put_model/1` raises for a model with none. To change catalog models' dialects, use a provider module's `models/2`. On llm_db, models marked `catalog_only` and models with no wire protocol or package are skipped, and OpenCode's fallback to Completions is gone: OpenCode loads 76 fewer models and NearAI 25 fewer there (all catalog-only), and OpenRouter's `auto` routers drop out (llm_db gives them image execution only).

**Custom providers need only config.** *(phase 1)*

```elixir
config :omni, :providers,
  gpu_box: [
    dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]},
    auth: :none,
    models: [
      [id: "llama-3.3-70b", dialects: %{text: Omni.Dialects.OpenAICompletions}],
      [id: "qwen3-32b", context_size: 32_768, dialects: %{text: Omni.Dialects.OpenAICompletions}]
    ]
  ]
```

**One id per provider, no renaming.** *(phase 1)* The id is the catalog key snake_cased; it is used for config, lookups and catalog lookups. The `provider_id:` source option is gone. Two instances of one provider aren't supported — use call-site `host:` and `api_key:` for a second region or key.

**Built-in quirks are compat flags.** *(phase 2)* Moonshot, Z.ai, Alibaba, NearAI, Venice and OpenRouter set compat flags in `config/0` instead of rewriting request bodies; inspect them with `Omni.get_provider(id)`. Groq's per-model effort clamping is gone — model thinking data does it for every provider. Venice keeps `models/2` (`:pdf` on every model); Groq keeps a small `modify_body/4` asking for parsed reasoning. Fixed along the way: Z.ai now sends `max_tokens` (it ignored `max_completion_tokens`, so `:max_tokens` had no effect); Groq asks non-gpt-oss reasoning models for parsed reasoning even when `:thinking` is unset (they inlined `<think>` tags in the answer).

**New built-in: Mistral (`:mistral`).** *(Mistral)* Mistral AI over Chat Completions, reading `MISTRAL_API_KEY`. Reasoning models take one effort, so every `:thinking` level sends `"high"`, and earlier thinking goes back as a thinking chunk at the head of the assistant message. Both sources now map `@ai-sdk/mistral` to Completions, so OpenCode Zen's `mistral-large-4` loads (it was skipped with a warning).

**New built-in: Together AI (`:togetherai`).** *(Together)* Together AI over Chat Completions, reading `TOGETHER_API_KEY`. Hybrid models switch thinking with `reasoning: {enabled: ...}`; effort models take `reasoning_effort`. Earlier reasoning is sent back in `reasoning`. Both sources map `@ai-sdk/togetherai` to Completions. The Completions parser also reads cached tokens reported flat on `usage` and Together's `"eos"` finish reason.

**Completions built-ins send earlier reasoning back.** *(thinking replay)* Moonshot, Z.ai, Alibaba, Venice and OpenCode Zen's Completions models send it in `reasoning_content`; Groq and Together in `reasoning`; Zen's Mistral models as a leading thinking chunk. Before, only OpenRouter and Mistral did. Providers that keep reasoning only within a tool loop still drop earlier turns'; to keep it, pass the provider's switch with `extra_body` (Alibaba `preserve_thinking: true`), or set it in a provider module where it nests inside a field Omni sets (Z.ai's `thinking.clear_thinking: false`; `extra_body` merges shallowly).

**New built-in: xAI (`:xai`).** *(xAI)* Grok models over the Responses API, reading `XAI_API_KEY`. Reasoning carries across turns as encrypted content. `thinking: false` switches off only models that list a `"none"` effort (`grok-4.3`); models with no effort data (`grok-4.20-0309-reasoning`, `grok-build-0.1`) get no `reasoning` at all, since they reject any effort. Both sources map `@ai-sdk/xai` to Responses, and llm_db's models (described as Chat Completions) are moved to Responses on load.

**New built-in: TypeSafe (`:typesafe`).** *(decisions)* TypeSafe's System One API at `https://api.typesafe.ai/v1`, reading `TYPESAFE_API_KEY`. Decision models only: `jev-1.14.0`, `jev-1.13.0`, `jev-latest` and `jev-preview`, listed by the module since models.dev has no TypeSafe entry.

**Decision endpoints on built-ins.** *(decisions)* OpenAI gains an OpenAI Decisions endpoint and gives `gpt-6-luna` the decision dialect beside its text one. OpenRouter, OpenCode Zen and NearAI load their catalog decision models over System One (OpenRouter at `/api/v1/systemone`, Zen at `/inference/systemone/v1`). Local Ollama gains a System One endpoint at `http://localhost:11434/v1`, which `host:` moves with chat; a decision model there names `dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}`. xAI and Ollama Cloud re-stamp only text models.

**OpenCode Zen requests go to per-API mounts.** *(decisions, snapshot refresh)* The catalog now mounts each API under `https://opencode.ai/inference/` (`openai/v1`, `anthropic/v1`, `google/v1beta`, `systemone/v1`) instead of serving all from `zen/v1`, and Omni follows it.

**Provider modules changed shape.** *(phase 1)*
- `use Omni.Provider, id: ..., dialect: ...` is gone; modules declare `@behaviour Omni.Provider` and carry no id.
- Attach a custom module with `module:` in the provider's config entry.
- All callbacks are optional: `config/0` (a keyword list of overrides), `models/2` (models plus the merged provider), `modify_request/3` and `modify_body/4`. *(phase 2)* These are settled, no longer provisional; `modify_deltas/3` is removed (parse-side variation lives in the dialect).
- Removed: `build_url/2`, `authenticate/2`, `modify_events/2`, `models/0`, `id/0`, `dialect/0`.
- Removed from `Omni.Provider`: `load_models/2`, `providers_from_config/1`, `build_model/2` (now `Omni.Source.build_model/1`).
- *(decisions)* `modify_body/4`'s third argument is what is being sent: a `%Omni.Context{}` for text, or a `%Omni.Decision{}` for a decision. A hook that reads `context.messages` should match on `%Omni.Context{}`.

**`Omni.Provider.load/1` takes ids**, or `{id, opts}` with inline config; reloading an id replaces its provider and models. *(phase 1)*

**New: `Omni.get_provider/1`.** *(phase 1)*

**Ollama Cloud streaming fixed.** *(phase 2)* ollama.com labels its NDJSON stream `application/json`, which Omni parsed as SSE, so every Ollama Cloud request ended in `{:error, :incomplete_stream}`. `application/json` responses are now read as NDJSON.

**Local Ollama sends no credentials** (`auth: :none`). *(phase 1)* In v1 a configured key was sent as a Bearer token. Behind an authenticating proxy, set `auth: :bearer` and `api_key:`. Its models are configured with `config :omni, :providers, ollama: [models: [...]]`.

**A missing API key is not a boot error.** *(phase 1)* Keys passed per call remain valid; a request without one fails with `{:error, :no_api_key}`, as before.

## Models

**`reasoning` is renamed `thinking`, and carries capability data.** *(phase 2)* `%Omni.Model{thinking: false | true | %{efforts: [...], toggle: true, budget: {min, max}}}`. `true` means the model reasons with no further detail; a map says which effort values (wire strings) it accepts, whether thinking switches on and off, and its budget range. Sources fill it from models.dev `reasoning_options`. `Model.new/1` (and config `models:` entries) take `thinking:`; `reasoning:` raises with a hint. Read `model.thinking != false` where you read `model.reasoning`.

**`%Omni.Model{}` fields changed.** *(phase 1)* `provider` is the embedded `%Omni.Provider{}` (was a module). `dialect` becomes `dialects`, a map from capability to dialect module: `%{text: Module}`, `%{decision: Module}`, or both.

**`Omni.Model.new/1`** accepts `provider:` as a struct or a loaded provider id. *(phase 1)* It never fills `dialects:` (see Providers, Dialects come from model data only).

**`Omni.put_model/1`** registers under the model's own provider (was `put_model/2`). The provider must be loaded. *(phase 1)*

**New: `filter:`** in `config :omni, :models` — `{Mod, :fun}` or a 1-arity function over every loaded model, including config-defined ones. *(phase 1)*

**New: `transform:`** in `config :omni, :models` — `{Mod, :fun}` or a 1-arity function that returns each loaded model changed or as is, run before `filter:`. It may change any field but `id` and `provider`; a model it leaves invalid (a dialect with no endpoint, say) raises at load. Its main use is moving a provider's models to another dialect the provider serves, an unverified, on-your-own feature: declare the endpoint under `config :omni, :providers` (`dialects: %{Omni.Dialects.OpenAIResponses => [base_url: ...]}`), then match the models in the transform. *(transform)*

**New: per-provider `models:`** — corrects or adds models (as ids or keyword lists of `Model.new/1` attributes). *(phase 1, endpoints)* An entry whose id the catalog has is merged over it, field by field (`dialects` by capability), so `[id: "gpt-6", context_size: 1_000_000]` corrects one field. An entry with a new id adds a model and names its dialect.

**Errors.** *(phase 1)* `{:error, {:unknown_provider, id}}` covers both a provider that doesn't exist and one not selected in `providers:`.

**New: string model references.** *(string refs)* Everywhere a `{provider_id, model_id}` tuple is taken, a string works too: `"provider:model"` or `"provider/model"` (`Omni.generate_text/3`, `stream_text/3`, `decide/3`, and the new `Omni.get_model/1` and `Omni.Model.get/1`, which take either form). The provider id ends at the first `:` or `/`, so model ids keep theirs (`"openrouter:typesafe/jev-1.14"`, `"ollama/qwen3:8b"`), and may be spelled as its catalog key (`"fireworks-ai:…"`). A bare model id is still not accepted. A string with no provider and model id to split is `{:error, {:invalid_model_ref, ref}}`; a provider that isn't loaded is `{:error, {:unknown_provider, name}}` with the name as written; then `{:unknown_model, provider_id, model_id}` as for tuples. `Omni.Model.to_ref/2` writes a model or tuple as `:tuple` (default, as before), `:colon` or `:slash`; `Omni.Model.parse_ref/1` reads a string into a tuple without looking the model up; `"#{model}"` gives the colon form (`String.Chars`). `Omni.Model.ref` is now the union of both forms.

**Models list every capability.** *(decisions)* `Omni.list_models/1` includes decision models (33 on OpenRouter). Filter with `Omni.Model.capability?(model, :text)`, or drop them in `filter:`. `Model.capabilities/1` lists a model's capabilities, the keys of `dialects`; `Model.dialect/2` returns `{:ok, module}` or `{:error, {:unsupported_capability, capability}}`.

**Fewer non-chat catalog models.** *(decisions)* The snapshot is models.dev's chat and decision models (`api.json?type=chat,decision`), and both built-in sources load a model by its catalog type. Realtime models (`openai:gpt-realtime-2.1`, `google:gemini-3.1-flash-live-preview`, which only work over websockets) and image-generation models that took tools (`google:gemini-3.1-flash-lite-image`, OpenRouter's `google/gemini-3-pro-image` and `google/gemini-nano-banana-2.1`) no longer load. Decision models load without tool use support.

## Requests

**`thinking: true` is `:medium`.** *(phase 2)* The same request as `thinking: :medium` on every model: switch-only models switch on, Claude adaptive models get effort `"medium"`, Gemini 3 level `"medium"`, Gemini 2.5 a 4096 budget.

**Thinking levels follow each model's capabilities.** *(phase 2)* A level rounds up to the nearest effort the model accepts, else down (so `:max` on gpt-oss sends `"high"`, `:low` on a `["minimal", "high"]` model sends `"high"`). Budget models get a budget from the level (low 1024, medium 4096, high 16384, xhigh 24576, max 32768), clamped to the model's range; `%{budget: n}` sets it exactly, on budget models only. `thinking: false` sends nothing to a model that can't switch off. Behaviour changes:
- Gemini 3 levels match by name (`:high` → `"high"`, was `"medium"`); `thinking: false` sends nothing to Gemini 3; Gemini 2.5 budgets follow the shared table and `:max` is the model's maximum budget (was `-1`).
- Anthropic uses adaptive thinking for models whose data lists efforts and no budget range (Claude 5 family, Opus 4.7+), replacing a hard-coded model list. Opus/Sonnet 4.6 move to budget thinking.
- Ollama models take string levels only when their data lists efforts; others take a boolean (local gpt-oss with no data configured now gets `true`).
- Moonshot, Z.ai and Alibaba models that list effort values get `reasoning_effort` instead of the provider's on/off switch.

**`input_tokens` excludes cached tokens on every dialect.** *(verification)* It already did on Anthropic; Completions, Responses, Gemini and Ollama counted cached tokens in both `input_tokens` and `cache_read_tokens`, so they were costed twice and `total_tokens` overcounted. Ollama now reports `prompt_eval_cached_count` as `cache_read_tokens`. Gemini's `output_tokens` now includes thinking (`thoughtsTokenCount`), which it bills as output, including when thinking spends the whole budget and Gemini reports no `candidatesTokenCount`. OpenAI's cache writes (`cache_write_tokens`) stay in `input_tokens`, billed at the input rate.

**A `:length` stop stands over tool calls.** *(fixture audit)* A response cut short inside a tool call reported `:tool_use`, and the loop ran the tool with the truncated input (`%{}`). It now reports `:length` and the loop stops; the truncated `ToolUse` stays in the message. Only `:stop` (Gemini's `STOP`, Ollama's `stop`) or a missing reason still becomes `:tool_use` when tool calls are present.

**OpenAI Responses carries reasoning across requests.** *(fixture audit)* Reasoning items become Thinking blocks with the item's id (`Thinking.id`, new) and its encrypted content as the signature, and go back in output order on later requests, so reasoning survives tool rounds with `store: false`. Reasoning models now send `include: ["reasoning.encrypted_content"]`. Reasoning items with no summary now appear as Thinking blocks with empty text.

**OpenAI Responses reports `:length` at `max_output_tokens`.** *(fixture audit)* `response.incomplete` was ignored, so the response failed with `:incomplete_stream`. It now ends with `:length` (`:refusal` for the content filter).

**Completions reads every packed tool call.** *(fixture audit)* A chunk carrying several calls in `delta.tool_calls` kept only the first.

**Completions reads list-form content and more tool call shapes.** *(Mistral)* `delta.content` as a list of thinking and text chunks was dropped, losing reasoning and some answer text; it now parses, including thinking signatures. Tool calls without `index` take their position in the list (several such calls collided at index 0), a continuation with `"name": ""` no longer starts a new call, and arguments sent as a JSON object are encoded to a string. `model_length` and `error` finish reasons map to `:length` and `:error` (were `:stop`).

**Thinking goes back only to the provider and dialect that produced it.** *(thinking from other models)* An assistant message from another provider or dialect, or with no origin, is sent without its thinking blocks, signatures (on text and tool uses) and `private`; text and tool uses are kept. Before, thinking went back whichever model wrote it, so switching from OpenAI or Gemini to Claude failed (`Invalid signature in thinking block`, or a nil signature). Behaviour changes:
- Assistant messages built by hand or decoded without an origin lose their thinking on replay. Set `origin` (`Message.new(origin: model)` takes the `%Model{}` that wrote it), or persist messages with `Omni.Codec`, to keep it.
- Completions providers no longer receive another provider's reasoning in `reasoning_content` or `reasoning`.
- Anthropic never sends thinking without a signature.
- Gemini sends `skip_thought_signature_validator` on the first unsigned tool use of each step in the current turn, so a tool loop from another model continues on Gemini 3.

**New: `Message.origin`.** *(thinking from other models)* `%{model: {provider_id, model_id}, dialect: module}` on assistant messages Omni produces, `nil` otherwise. `Message.new/1` builds it from a `%Model{}` passed as `:origin`. `Omni.Codec` encodes it as `%{"model" => "provider:model", "dialect" => "Omni.Dialects.…"}` (a string model reference; `"provider/model"` also decodes); a provider that isn't loaded or an unknown dialect decodes as `nil`.

## Decisions

**New: `Omni.decide/3`.** *(decisions)* A second capability beside text: one shared input (the state) and a keyword list of typed questions, answered with probabilities in one JSON request. Not streamed.

```elixir
{:ok, decision} =
  Omni.decide({:openai, "gpt-6-luna"}, {ticket_text, [
    urgent: Omni.predicate("Does this need a reply within the hour?"),
    team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
    anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
  ]})

decision.answers[:team]  #=> %Omni.Answer.Choice{choice: :infra, probabilities: [billing: 0.02, infra: 0.95, other: 0.03], confidence: 0.93}
```

- `%Omni.Decision{state, questions, answers, usage, model, raw}` is both the request and the result; `decide/3` also takes the `{state, questions}` shorthand.
- The state and each question's instructions are lists of parts, `Omni.Content.Text` and the new `Omni.Content.Data` (structured data sent as JSON). Give a string, a map, or a list of strings, maps and parts; `Decision.new/1` and the question constructors build the parts. `Data.new/1` normalises its map through JSON (string keys). A list means one part per item, so an array of data goes inside a map.
- Questions: `Omni.Question.Predicate`, `Choice`, `Score`, built with `Omni.predicate/2`, `Omni.choice/2`, `Omni.score/2`. Choices and levels are a list of keys or `key: description` pairs; keys come back as given.
- Answers: a keyword list aligned with the questions, of `Omni.Answer.Predicate{probability}`, `Choice{choice, probabilities, confidence}`, `Score{score, probabilities, confidence}` and `Refusal{}` (OpenAI, and OpenRouter over System One). Probabilities are `{key, float}` pairs in the question's order, passed through unrounded; confidence is the provider's own number, or `nil`.
- Options: `api_key`, `host`, `headers`, `timeout`, `raw`, `plug`; OpenAI Decisions adds `safety_identifier` and `prompt_cache_key`.
- Errors: invalid questions fail before any request (at least one question, non-empty instructions, two or more choices or levels); an answer missing, unasked for or of the wrong type is `{:error, {:invalid_answer, name}}`.
- Two dialects: `Omni.Dialects.TypeSafeSystemOne` (TypeSafe's format, served by TypeSafe, OpenRouter, OpenCode Zen, Ollama, NearAI) and `Omni.Dialects.OpenAIDecisions`. Built-in endpoints are under Providers.

**Capability errors.** *(decisions)* `generate_text/3` and `stream_text/3` on a model with no text dialect return `{:error, {:unsupported_capability, :text}}`; `decide/3` on one with no decision dialect `{:error, {:unsupported_capability, :decision}}`. Both before any HTTP.

**New: `Omni.Usage.price/2`.** *(decisions)* Computes a usage's costs from a model's pricing; both text responses and decisions use it.

**`Omni.Codec` encodes decisions.** *(decisions)* `%Omni.Decision{}`, the `Omni.Question` structs and the `Omni.Answer` structs round-trip through `encode/1` and `decode/2`. The model is stored as a string reference and looked up on decode (`nil` if not loaded); `raw` is not stored. Atom choice and level keys encode as `%{"atom" => "key"}`, string keys as plain strings, so each comes back as given.

**`Omni.Codec.decode/2` and `decode_term/2` take `atoms:`.** *(decisions)* By default decoding creates no atoms: an unknown question name or atom key is `{:error, {:unknown_atom, name}}`, and an opaque blob (`Message.private`, `Attachment.meta`) holding an unknown atom fails with `{:error, {:invalid_etf, _}}`, as before. `atoms: :create` creates them, for data the app wrote itself (atoms built at runtime, or modules not yet loaded in development); never for untrusted input. A non-list `content` or state now decodes to `{:error, :invalid_input}` instead of raising.

## Sources

**`Omni.Source.build_model/1` reads `"reasoning_options"`** (models.dev's list form, string or atom keys) into `:thinking`. *(phase 2)* The llm_db source passes them through, falls back to OpenRouter's `supported_efforts`, and reads `extra` with string keys as well as atom keys (llm_db 2026.7.2+).

**`Omni.Source.fetch/2` changed.** *(phase 1, endpoints)* It takes a provider id (not a module) and returns `{:ok, provider, models}`: a partial `%Omni.Provider{}` from the catalog's provider record, with an endpoint and whole URL per dialect its models speak (templated URLs kept for `host:`), and models without a provider, each with its dialects from catalog data. Nothing fills in a dialect the source can't map.

**Skipped models.** *(phase 1, endpoints)* Both built-in sources skip, with a warning, models whose npm package (their own, else their provider's) maps to no dialect, and a model at another URL than the first model of its dialect (only google-vertex in the bundled catalog).

**`Omni.Source.build_model/1` takes `"dialects"`.** *(decisions)* A list of dialect names, each placed under the capability its module serves (`["openai_responses", "openai_decisions"]` → `%{text: ..., decision: ...}`), replacing the single `"dialect"` string. Two dialects for one capability raise.

## Dialects

**`GoogleGemini` is renamed `GoogleGenerateContent`.** *(dialect names)* `Omni.Dialects.GoogleGemini` becomes `Omni.Dialects.GoogleGenerateContent` and its string id `"google_gemini"` becomes `"google_generate_content"`, naming the API it speaks as the other dialects do and leaving room for Google's Interactions API, a different wire format on the same host. Update `dialects:` config and `Omni.Dialect.get/1` calls; nothing else changes on the wire.

**Dialects declare their capability with `use Omni.Dialect`.** *(decisions)* `Omni.Dialect` is now the base every dialect shares (`auth/0`, `compat_schema/0`, the registry, `compat/2`); the callbacks that build requests and read responses moved to one behaviour per capability, `Omni.Dialect.Text` and `Omni.Dialect.Decision`. A custom text dialect replaces `@behaviour Omni.Dialect` with `use Omni.Dialect, :text`, which declares both `Omni.Dialect` and `Omni.Dialect.Text`; its callbacks are unchanged. A decision dialect uses `use Omni.Dialect, :decision` and implements `option_schema/0`, `handle_path/2`, `handle_body/3` (with a `%Omni.Decision{}`) and `handle_response/3` (the decoded JSON body to an answered decision). `Omni.Dialect.capability/1` reads the declared behaviour, so a module without it is not a dialect and fails at load. A model's `dialects:` map must name each dialect under its own capability (`%{text: Omni.Dialects.TypeSafeSystemOne}` raises for a config model, is skipped for a catalog model).

**New required callback `compat_schema/0`.** *(phase 2)* A Peri schema of the compat flags the dialect understands; return `%{}` for none. Read a provider's flags with `Omni.Dialect.compat(model, __MODULE__)`. `Omni.Dialects.OpenAICompletions` documents its flags; the other built-in dialects have none yet.

**`thinking_replay_field` is now `thinking_replay_format`.** *(Mistral)* On `Omni.Dialects.OpenAICompletions`: `thinking_replay_field: "reasoning_details"` becomes `thinking_replay_format: :reasoning_details`. New values: `:content_chunks` (thinking as a leading `content` chunk), `:reasoning_content` and `:reasoning` (thinking text in that field; *thinking replay*), and `:none`.

**`handle_event/2` receives the model.** *(phase 2)* `handle_event(event, model)` (was `handle_event/1`).

**New optional text callback `handle_message/2`.** *(reasoning details)* `handle_message(message, model)` receives the assembled assistant message once a stream completes and returns it, for work that needs the whole stream. OpenRouter's streamed `reasoning_details` are now merged into one entry per reasoning block (was one entry per streamed fragment), so they are smaller in `Message.private` and when sent back.

**New: `Omni.Dialect.Thinking`.** *(phase 2)* Resolves the `:thinking` option against a model's thinking data — shared clamping and budgets for custom dialects too.

**New required callback `auth/0`.** *(phase 1)* Returns `:bearer` or `{:header, name}` — the home API's key scheme. Custom dialects must implement it.

**`handle_path/2` returns resource paths only** (`/chat/completions`, not `/v1/chat/completions`). *(phase 1)*

## Tooling

**New: `mix omni.verify <provider>:<model>`.** *(verification, decisions, string refs)* The model is a string reference (`anthropic:claude-haiku-5-5`, a slash works too) or the provider and model ids as two arguments. Runs live scenarios against one model and reports pass or fail for each, with a short reason per failure and the full error for failures from an error. The defaults follow the model's capabilities: text, thinking, tool use and structured output for a text model; `decision` (a string state with a predicate, a choice and a score) and `decision_json` (a map state and map instructions) for a decision model; all six for a model with both. On request: no thinking, image, PDF, a multi-turn tool loop with thinking (`kitchen_sink`) and cache usage (`--only`, `--add`, `--skip`, `--delay`). Works for built-in, catalog and custom providers; a catalog provider that isn't loaded is loaded for the run. Exits non-zero on any failure.
