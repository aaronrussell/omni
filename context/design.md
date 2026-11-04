# Omni Design Document

**Status:** Implemented (v2 branch)
**Last updated:** November 2026

---

## Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. The core challenge is managing a large, ever-changing catalog of models across many providers, where providers share a small number of underlying API formats but each has its own endpoint, authentication, and quirks.

The design separates three distinct concerns:

- **Models** -- data describing a specific LLM (capabilities, pricing, limits)
- **Providers** -- data describing a specific service: where requests go, how they authenticate, and how it deviates from the wire format it speaks
- **Dialects** -- code for the wire format of a family of APIs (how requests are built and responses are parsed)

Omni serves two **capabilities**, kinds of request: **text** generation (`generate_text/3`, `stream_text/3`; streamed, with tools, thinking and structured output) and **decisions** (`decide/3`; typed questions over a shared input, answered with probabilities in one JSON response). See [Decisions](#decisions).

The relationship: there are seven dialects (five text, two decision), hundreds of possible providers (17 built-ins; any provider in the models.dev catalog loads by id; most speak one dialect, though gateways like OpenCode Zen use several), and thousands of models (each belonging to one provider). Each `%Model{}` embeds its `%Provider{}` and names its dialect per capability (`dialects: %{text: Module, decision: Module}`), so dispatch is always per-model and nothing is looked up at request time.

---

## Top-Level API

### Core functions

```elixir
Omni.generate_text(model, context, opts \\ [])  # -> {:ok, %Response{}} | {:error, reason}
Omni.stream_text(model, context, opts \\ [])     # -> {:ok, %StreamingResponse{}} | {:error, reason}
Omni.decide(model, decision, opts \\ [])         # -> {:ok, %Decision{}} | {:error, reason}
```

All return `{:ok, result} | {:error, reason}` because errors can occur before the request starts (model not found, invalid context/options, auth failures, bad status codes). These surface immediately at the call site rather than falling out mid-stream. Calling one on a model without the capability is `{:error, {:unsupported_capability, :text | :decision}}`, before any HTTP.

Alongside them: `get_model/2`, `list_models/1`, `put_model/1`, `get_provider/1`, and constructors (`context/1`, `message/1`, `tool/1`; `predicate/2`, `choice/2`, `score/2` for decisions).

### Streaming-first design

All text requests use streaming HTTP under the hood (decisions don't: no decision API streams). Each dialect implements a streaming request and normalises the provider's streaming events into a unified delta format. `generate_text` is built on top of `stream_text`:

```elixir
def generate_text(model, context, opts \\ []) do
  with {:ok, stream} <- stream_text(model, context, opts) do
    Omni.StreamingResponse.complete(stream)
  end
end
```

This means one code path through the dialect, one set of tests for the wire format. The non-streaming version is simply accumulation over the stream. See the [Streaming](#streaming) section for the full streaming design.

### Model argument

The `model` parameter accepts:

- **Model struct** -- if the caller has already looked up (or built) the model
- **Provider/model tuple** -- `{:anthropic, "claude-sonnet-5-5"}`

Bare string model IDs are not supported to avoid ambiguity when the same model ID appears on multiple providers.

```elixir
# With a tuple (most common)
Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, context)

# With a pre-fetched struct
{:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
Omni.generate_text(model, context)
```

### Context argument

The `context` parameter accepts multiple formats, coerced by `Context.new/1`:

- **String** -- treated as a single user message
- **Message list** -- a conversation with no system prompt or tools
- **Context struct** -- the full representation with system prompt, messages, and tools

```elixir
# Simple prompt string
Omni.generate_text(model, "What is the capital of France?")

# List of messages
Omni.generate_text(model, [
  Omni.message(role: :user, content: "Hello"),
  Omni.message(role: :assistant, content: "Hi there!"),
  Omni.message(role: :user, content: "What's the weather?")
])

# Full context
Omni.generate_text(model, Omni.context(
  system: "You are a weather assistant",
  messages: messages,
  tools: [weather_tool]
))
```

The `Omni.Context` struct represents the "what" -- everything the model needs to know:

```elixir
%Omni.Context{
  system: "string",       # optional system prompt
  messages: [message],    # conversation history
  tools: [tool]           # available tools
}
```

The litmus test for what belongs in context vs options: **context is "what the model knows", options are "how to behave"**. A future `tool_choice` would be an option (a behavioural directive) even though `tools` is in context.

### Options argument

Options are a flat keyword list. The caller doesn't need to categorise them -- each layer takes the keys it owns.

```elixir
Omni.generate_text(model, context,
  # Inference options (validated by Omni.Request, encoded by the dialect)
  max_tokens: 4096,
  temperature: 0.7,
  thinking: :high,
  cache: :short,
  output: schema,
  metadata: %{user_id: "u_123"},

  # Loop options (taken by Omni.Loop before the request is built)
  max_steps: 5,
  tool_timeout: 30_000,
  raw: true,

  # Request config (merged over the provider's values)
  api_key: "sk-ant-...",
  host: "https://custom-proxy.com",   # swaps the endpoint URL's origin, keeps its path
  headers: %{"x-custom" => "value"},
  timeout: 300_000
)
```

The universal text options are deliberately minimal: `max_tokens`, `temperature`, `thinking`, `cache`, `output`, `metadata`. `decide/3` takes only the request config keys (`api_key`, `host`, `headers`, `plug`, `timeout`) and `raw`. A dialect may add its own through `option_schema/0` (Anthropic Messages, to default `max_tokens` to 4096; OpenAI Decisions, for `safety_identifier` and `prompt_cache_key`). Validation is one strict Peri pass, so an unknown key is an error.

Request config resolves in two tiers: **call-site opts**, then **the provider struct**. The provider already absorbed its source data, module `config/0`, and app config when it loaded, so there is no per-request config lookup. Headers merge by key; other values replace.

This means models stay as pure data -- they never carry a resolved API key. `api_key` is resolved at request time (`Provider.resolve_auth/1`) from a literal string, `{:system, "ENV"}`, or `{Mod, :fun, args}`.

### Caching

The `cache` option controls explicit prompt caching hints. It does not enable or disable caching -- some providers (OpenAI, Gemini) cache implicitly by default regardless of this option. The option tells Omni to add explicit caching directives to the request where the provider supports them.

```elixir
Omni.generate_text(model, context, cache: :short)
```

The accepted values are:

- **`nil`** (default) -- no explicit caching directives. Providers with implicit caching may still cache.
- **`:short`** -- explicit caching with a short TTL (typically 5 minutes).
- **`:long`** -- explicit caching with an extended TTL (typically 1 hour or more).

Each dialect translates the option into the appropriate mechanism:

| Option | Anthropic Messages | OpenAI Responses | OpenAI Completions | Gemini, Ollama |
|--------|--------------------|------------------|--------------------|----------------|
| `nil` | No breakpoints | Nothing sent | Nothing sent | Nothing sent |
| `:short` | Breakpoints, 5min TTL | Nothing sent (default retention) | Nothing sent | Nothing sent |
| `:long` | Breakpoints, 1h TTL | `prompt_cache_retention: "24h"` | `prompt_cache_retention: "24h"` | Nothing sent |

For Anthropic, the dialect places `cache_control` breakpoints on the system prompt, the tools, and the last message content block. The provider's prefix matching handles the rest -- previous messages that match the cached prefix get cache hits automatically, even as new messages are appended. Where a dialect has no mechanism, the option is silently ignored (caching is an optimisation hint, not a semantic requirement). A provider that rejects the Completions field drops it with `omit: [:cache]` in its Completions endpoint's compat.

---

## Models

### What a model is

A model is a data struct -- not a module. It describes a specific LLM's identity, capabilities, and pricing, and carries everything a request needs: its provider and its dialect.

```elixir
%Omni.Model{
  id: "claude-sonnet-5-5",           # the provider's model id
  name: "Claude Sonnet 5.5",
  provider: %Omni.Provider{...},     # embedded, not an id
  dialects: %{text: Omni.Dialects.AnthropicMessages},  # one module per capability
  context_size: 1_000_000,
  max_output_tokens: 128_000,
  thinking: %{efforts: ["low", "medium", "high", "xhigh", "max"]},
  input_modalities: [:text, :image, :pdf],
  output_modalities: [:text],
  input_cost: 2.0,                   # USD per million tokens
  output_cost: 10.0,
  cache_read_cost: 0.1,
  cache_write_cost: 2.5,
  release_date: ~D[2026-09-28]
}
```

- **`provider` is the struct itself.** Within one persistent term every model of a provider shares one copy of it, so embedding costs nothing, and a `%Model{}` is self-contained: the request pipeline reads `model.provider` and `model.dialects` and nothing else. `Model.to_ref/1` reads `provider.id`.
- **Capabilities are the keys of `dialects`** (`:text`, `:decision`), each naming the dialect that serves it. Most models have one; `openai:gpt-6-luna` has both. Read with `Model.capabilities/1`, `capability?/2` and `dialect/2` (`{:ok, mod}` or `{:error, {:unsupported_capability, cap}}`). There is no `type` field: it would restate the keys and couldn't describe a model serving both. A capability is a kind of request; a **modality** is a kind of content (`:text`, `:image`, `:pdf`), and `:text` is both, so helpers name the capability and modalities get none.
- **The struct is flat.** Per-capability nesting (`capabilities: %{text: %{dialect, thinking, input}}`) was rejected: catalogs give one record per model id, so it would mostly copy data. `thinking` and tool use are text features: decision models have `thinking: false`, and every catalog text model supports tool use (sources leave out the rest, since such models are of little use).
- **`thinking`** is `false` (no reasoning), `true` (reasons, nothing more known), or a map of what the model accepts (`:efforts`, `:toggle`, `:budget`). See [Thinking](#thinking).
- Supported modalities are defined on `Omni.Model`: input `:text`, `:image`, `:pdf`; output `:text` (a decision's answers count as text). Anything else in catalog data is dropped.

`Model.new/1` takes `provider:` as a struct or the id of a loaded provider, and accepts `thinking:` as a boolean, map, or keyword list (an empty map means `true`). It never fills `dialects` from the provider: a model names its own, and `Omni.put_model/1` raises for one with none. It does not validate values; validation happens at the API boundary.

### Where model data comes from -- model sources

Catalog data comes from a pluggable **model source**: a module implementing the `Omni.Source` behaviour (marked experimental). A source answers one question -- *what does your catalog say about this provider?* -- in one call:

```elixir
@callback fetch(id :: atom(), opts :: keyword()) ::
            {:ok, Omni.Provider.t(), [Omni.Model.t()]} | {:error, term()}
```

It receives the provider's id and returns **raw catalog data only**:

- a partial `%Provider{}`: `id`, plus whatever the catalog knows of `name`, `api_key` (`{:system, var}` only when the catalog names exactly one variable -- several variables signal bespoke credentials that need config), and `dialects`: an endpoint per dialect its models speak, holding the catalog's whole URL for it;
- models **without** a provider, each with `dialects` from its own catalog data. A model the catalog gives no dialect for is skipped, since Omni never fills one in.

Translating the id to the catalog's key is the source's job (`Omni.Sources.ModelsDev` hyphenates; `Omni.Sources.LLMDB` uses it verbatim). `Omni.Source.build_model/1` builds a model from a string-keyed map (dates, defaults, `"reasoning"` and `"reasoning_options"` into `:thinking`, and `"dialects"`, a list of dialect names each placed under the capability its module serves; two for one capability raise).

**Eligibility by type.** A catalog model loads for one capability by its catalog type: untyped or `chat` → text, which needs tool use and text in and out; `decision` → decision, which needs text in. Every other type (image, embedding, realtime, ...) and deprecated models are left out. Decision models read their own dialect table, with no provider-level fallback: models.dev `@ai-sdk/typesafe-ai` → SystemOne, `@ai-sdk/openai` → OpenAIDecisions; llm_db `execution.evaluate.family` `typesafe_systemone`/`openrouter_decisions` → SystemOne, `openai_decisions` → OpenAIDecisions (`cloudflare_ai_run` skipped). llm_db's `gpt-6-luna` arrives with both capabilities; models.dev's `type` is one exclusive string, so OpenAI's module stamps it. `Omni.Source.endpoints/3` derives the endpoints from the models' URLs: each dialect takes the URL of its first model by id (the model's own catalog URL, else the provider's), on whatever path or host that is; the provider-level dialect gets the provider URL when no model claimed it; a provider URL with no dialect is dropped. Templated URLs (`${VAR}`, `{var}`) are kept for `host:` to fill. Sources skip, with a warning, models they can't represent faithfully: a model whose npm package -- its own, or its provider's when it has none -- maps to no dialect Omni speaks (the catalog says it speaks another API; a provider-level miss is logged at debug and counted in the summary), and a model at another URL than the first model of its dialect (only google-vertex has one in the bundled catalog). The llm_db source also skips models llm_db marks `catalog_only` and models with no wire protocol or npm package. `{:error, :unknown_provider}` means the catalog doesn't know the id, so the provider is custom; any other error is logged and treated the same way. There is no cross-source fallback.

The npm-package-to-dialect table lives in each source. A bespoke package that is OpenAI-compatible in practice (`@ai-sdk/xai`, `@ai-sdk/togetherai`, ...) is mapped there when its provider becomes a built-in, not before: these providers have no catalog URL, so a mapping without the module adds little.

Omni ships two sources:

- **`Omni.Sources.ModelsDev`** (default) -- reads a snapshot of the full [models.dev](https://models.dev/) catalog bundled in the package (`priv/models/models_dev.json`, refreshed with `mix omni.snapshot` and committed to the repository). The snapshot content is verbatim; only the encoding is normalized (pretty-printed, keys sorted) so snapshot updates produce minimal, reviewable git diffs. It holds models.dev's chat and decision models (`api.json?type=chat,decision`; the default endpoint also carries image, embedding, video, speech and realtime models). It is transformed at load time by the eligibility rule above, each text model's dialect inferred from npm package metadata (the model's own package, else its provider's). The provider record supplies `name`, `api` (the URL for its provider-level dialect, unless a model carries its own), `env` and `npm`. Because the snapshot is unpruned, any catalog provider can be loaded by id. An optional **live mode** (`source: {Omni.Sources.ModelsDev, live: true}`) fetches fresh catalog data from models.dev at boot with a disk cache (`cache_ttl:`, `cache_dir:` opts), degrading gracefully: fresh cache → fetch → stale cache → bundled snapshot, warning at each step.
- **`Omni.Sources.LLMDB`** -- sources the catalog from the optional [`llm_db`](https://hex.pm/packages/llm_db) hex package. Selecting it without the package in deps raises at boot. Text dialects come from the wire protocol, then npm metadata; decision dialects from `execution.evaluate`. Filtering and freshness are llm_db's own concerns (`config :llm_db, allow:/deny:/sources:`), deliberately not wrapped by Omni.

The source is chosen per provider (`config :omni, :providers, openai: [source: ...]`), else globally (`config :omni, :models, source: ...`), else the default. A source value is a module or a `{module, opts}` tuple.

A CI golden test runs the ModelsDev transform over the bundled snapshot and asserts invariants (resolved dialects, per-provider count ranges, exact golden models) -- the quality gate for the shipped snapshot + transform combination.

**Snapshot refresh and release policy.** models.dev changes multiple times a day; the bundled snapshot does not chase that churn -- live mode is the freshness valve for users who need current data, so the snapshot only needs to be good as a default and an offline fallback. The policy:

1. **Every release refreshes the snapshot** -- running `mix omni.snapshot` (and updating the golden test expectations) is a release checklist step, so no release ships staler data than it has to.
2. **Event-driven data patches** -- a data-only patch release is cut when a change users actually feel lands in the catalog: a major model family launch, or a pricing change that affects cost computation. Routine catalog noise does not trigger a release.
3. **Monthly backstop** -- at least one release per month, even if it is only a snapshot refresh.

### Storage and lookup

Providers and models are stored in `:persistent_term` -- a global key-value store built into the BEAM, optimised for data written rarely and read often (reads are essentially free: no message passing, no copying). Two kinds of key:

```elixir
{Omni, :providers}        # %{id => %Provider{}}
{Omni, :models, id}       # %{model_id => %Model{}}, one term per provider
```

One models term per provider keeps `list_models/1` O(1) and lets `put_model/1` rewrite a single provider's term. Writes go through `Omni.Provider.Loader` under a lock. Writing a changed persistent term scans every process heap, so loading and `put_model/1` are boot or on-demand operations, never per request. There is no whole-catalog mode and no lazy loading: the `providers:` selection bounds what loads.

Lookup checks the provider first, so a provider that doesn't exist and one that exists but wasn't selected return the same error:

```elixir
Omni.get_model(:anthropic, "claude-sonnet-5-5")
#=> {:ok, %Model{}}
#=> {:error, {:unknown_provider, :anthropic}}       # not loaded
#=> {:error, {:unknown_model, :anthropic, "..."}}   # loaded, no such model
```

`put_model/1` registers a model under its own (loaded) provider. Users can also build a `%Model{}` and pass it straight to `stream_text/3` without registering it.

### Why not an Agent or GenServer for storage?

An Agent serialises all access through a single process mailbox. For a read-heavy lookup table (written once at startup, queried from many concurrent processes), this creates an unnecessary bottleneck. `:persistent_term` gives concurrent reads from any process with zero overhead.

---

## Providers

### What a provider is

A provider is an LLM service, described as data: a `%Omni.Provider{}` struct assembled once, when the provider loads, and embedded in every model it serves. It is the authenticated HTTP layer -- it knows *where* to send requests, *how* to authenticate them, and *how this service deviates* from the wire format it speaks -- but not what a request body looks like in general (that's the dialect's job).

```elixir
%Omni.Provider{
  id: :groq,                                     # catalog key, snake_cased
  name: "Groq",
  api_key: {:system, "GROQ_API_KEY"},            # string | {:system, var} | {M, F, A} | nil
  auth: :dialect,                                # :bearer | {:header, name} | :none | :dialect
  headers: %{},
  dialects: %{                                   # an endpoint per dialect it serves
    Omni.Dialects.OpenAICompletions => %Omni.Provider.Endpoint{
      base_url: "https://api.groq.com/openai/v1",  # the whole URL, version segment included
      compat: %{thinking_replay_format: :reasoning}
    }
  },
  module: Omni.Providers.Groq                    # optional code for what flags can't express
}
```

- **`dialects` maps each dialect the provider serves to an endpoint**: its whole base URL and its compat flags. A request goes to `endpoint.base_url <> dialect.handle_path(model, opts)`, so a gateway serves each dialect from its own path or host (OpenCode's live catalog mounts `/inference/openai/v1`, `/inference/anthropic/v1`, `/inference/google/v1beta`; freemodel serves Anthropic from `cc.freemodel.dev` and Completions from `api.freemodel.dev`). See [Endpoints](#endpoints).
- **`base_url` includes the version segment** (`/v1`, `/v1beta`, `/api/paas/v4`), as SDKs and API docs mean it. Dialect paths are resource paths only (`/chat/completions`, `/messages`). This follows the catalog (190 of the ~200 catalog base URLs include it) and the OpenAI SDK convention, and removed every URL-building override. The few catalog base URLs without a version segment (`https://api.deepseek.com`, `https://api.githubcopilot.com`) are roots those APIs serve directly, not omissions. Local Ollama's documented root has no version, so its dialect path stays `/api/chat`.
- **Auth, headers and the API key stay on the provider.** Nobody configures them per dialect; what varies per dialect is the resolution of `:dialect` to the home scheme, done per request. A provider is one account: a different key means a different provider id.
- **`auth` is pure data.** `:dialect` (the default) means "use the scheme of the dialect's home API" (`Dialect.auth/0`: Anthropic Messages → `x-api-key`, Gemini → `x-goog-api-key`, OpenAI → bearer). That is how a gateway like OpenCode Zen authenticates each model the way its upstream does, with no code. No function-valued forms; anything exotic goes through `modify_request/3`.
- **No dialect is a default.** Each model names its own dialect; the provider's endpoints say where each is served. `Omni.Provider.dialects/2` lists a capability's dialects, read through `Omni.Dialect.capability/1`.
- **No `tier` field.** v2 briefly stamped `tier: :verified | :catalog | :custom`. Nothing read it, built-in membership is `Omni.Provider.builtins/0`, and "verified" promised something about a whole provider that is only ever checked model by model. Removed before release.

### Why providers are data

In v1 every provider was a module, and the module was the identity everywhere (config keys, store keys, source lookups, `Model.to_ref/1`). That meant Omni could never offer the hundreds of OpenAI-compatible endpoints in the catalog without writing hundreds of modules, and users couldn't add a provider without code even when the catalog already knew it. Auditing the modules showed two more problems:

- **`modify_body` was a post-hoc rewrite coupled to dialect internals.** Every implementation pattern-matched keys the dialect had emitted (`"reasoning_effort"`, `"response_format"`, `"max_completion_tokens"`) and undid them.
- **The dialect/provider boundary had already eroded.** The Completions dialect knew about OpenRouter, vLLM, Z.ai and Venice parsing differences. Variation was ending up in the dialect anyway, which argued for putting it there on purpose.

So providers became data, and provider quirks became **compat flags** that dialects read while encoding. Prior art (Pi in particular) showed that flags scale to hundreds of providers and that every dialect eventually needs its own set, but also that auto-detecting quirks from provider name or base URL is fragile: a user who overrides a region silently loses them. Omni's defaults therefore come from explicit per-provider data, and flags are named by wire shape, not by provider.

### Built-in, catalog and custom

Any provider can be loaded; Omni knows more about some than others. These are plain descriptions of where a provider's definition comes from, not a field on the struct.

| Kind | What it is | What Omni supplies |
|---|---|---|
| Built-in | An id in `Omni.Provider.Builtins`, with a module in `Omni.Providers.*` | Endpoint URLs, key variable and compat set explicitly; quirks in its moduledoc; baseline fixtures and a provider test; models in the sweep matrix |
| Catalog | Any other provider the source's catalog knows | Endpoint URLs, key variable, models and dialects from catalog data; speaks each dialect plain, with no flags. The user sets flags, or borrows a built-in's with `like:` |
| Custom | An id the catalog doesn't know | Nothing beyond what config defines |

Omni doesn't call a provider "verified". Verification is per model and per day (see [Verification and testing](#verification-and-testing)): a built-in has had some of its models run against its live API, never all of them. Users check any model, on any kind of provider, with `mix omni.verify`.

**Built-in config never guesses.** Flags inferred from what other libraries do are not built-in config; they are the starting point for running verify. A provider becomes a built-in only once its models have been run against its live API.

### Built-in providers

**Stamp, don't invent.** A built-in module may add a capability to a model the catalog has (OpenAI and `gpt-6-luna`), and may list models only for a provider the catalog has no entry for (TypeSafe, local Ollama). It never adds models to a provider the catalog knows: Ollama Cloud, Alibaba and Venice serve System One but wait for catalog data (see the roadmap).

Built-ins keep modules. `Omni.Provider.Builtins` (internal) maps the seventeen built-in ids to `Omni.Providers.*` modules, and each module's `config/0` *is* the built-in overlay: its endpoint URL, key variable, and compat, set explicitly under `dialects:` even where the catalog agrees, so `like:` has a complete set to copy. OpenCode is the exception for URLs: it sets only compat and takes each dialect's URL from the catalog, which knows the gateway's mounts. Their moduledocs are the per-provider reference (quirks, regions, the flags they set). Modules carry no id; the Builtins map supplies it, and other providers attach a module with `module:` in config.

| Id | Module | Text | Decision | Module code beyond `config/0` |
|---|---|---|---|---|
| `:alibaba` | `Alibaba` | Completions | -- | -- |
| `:anthropic` | `Anthropic` | Anthropic Messages | -- | -- (`anthropic-version` header in `config/0`) |
| `:google` | `Google` | Gemini | -- | -- |
| `:groq` | `Groq` | Completions | -- | `modify_body/4`: `reasoning_format: "parsed"` |
| `:mistral` | `Mistral` | Completions | -- | -- |
| `:moonshotai` | `Moonshot` | Completions | -- | -- |
| `:nearai` | `NearAI` | Completions | System One (catalog URL, unverified) | -- |
| `:ollama` | `Ollama` | Ollama Chat | System One | `models/2`: stamps Ollama Chat on config models with no dialect (`auth: :none`, models from config) |
| `:ollama_cloud` | `OllamaCloud` | Ollama Chat | -- | `models/2`: re-stamps text models to Ollama Chat |
| `:openai` | `OpenAI` | Responses | OpenAI Decisions | `models/2`: adds the decision dialect to `gpt-6-luna` |
| `:opencode` | `OpenCode` | per model | System One (catalog URL) | `modify_body/4`: Mistral reasoning as a leading chunk |
| `:openrouter` | `OpenRouter` | Completions | System One | -- |
| `:togetherai` | `Together` | Completions | -- | -- |
| `:typesafe` | `TypeSafe` | -- | System One | `models/2`: TypeSafe's documented models |
| `:venice` | `Venice` | Completions | -- | `models/2`: adds `:pdf` to every model |
| `:xai` | `XAI` | Responses | -- | `models/2`: re-stamps text models to Responses; `modify_body/4`: no `reasoning` without effort data |
| `:zai` | `Zai` | Completions | -- | -- |

Each piece of residual code exists because no flag could express it:

- **Groq `modify_body/4`.** Groq's `reasoning_format` defaults to `raw` (`<think>` tags in the content) on reasoning models other than gpt-oss, which doesn't support the parameter. The module sends `"parsed"` to non-gpt-oss reasoning models unless thinking is off. It depends on the model id, so it isn't a provider-wide flag.
- **Ollama `models/2`.** A local instance's models come from config by id alone, and Omni never fills a dialect in, so the module stamps Ollama Chat on those with none. An entry naming its own dialect keeps it.
- **Ollama Cloud `models/2`.** The catalog describes Ollama's OpenAI-compatible endpoint (`https://ollama.com/v1`, which stays as an unused endpoint); Omni uses the native chat API at `https://ollama.com`. Model data decides a model's dialect, so changing catalog models' dialects takes code. It runs after config `models:` merge, so it also replaces a dialect set there. Like xAI's, it re-stamps only text models (and config models with no dialect), leaving decision models alone.
- **OpenAI `models/2`.** `gpt-6-luna` serves Responses and Decisions on one id, which models.dev's single `type` can't say, so the module adds `decision: OpenAIDecisions` to it.
- **OpenCode `modify_body/4`.** Zen passes Mistral's wire through, and Mistral rejects unknown fields, so `mistral-*` models get their earlier reasoning as a leading thinking chunk rather than `reasoning_content`. It varies by model within one dialect.
- **TypeSafe `models/2`.** models.dev has no TypeSafe entry, so the module adds TypeSafe's documented models (`jev-1.14.0`, `jev-1.13.0`, `jev-latest`, `jev-preview`) for ids the source and config don't have. Not "only when the catalog has none": config is merged in before `models/2`, so that would drop the list as soon as config added a model.
- **Venice `models/2`.** Venice extracts PDF text at its API layer for every model, which the catalog doesn't record.
- **xAI `models/2`.** llm_db describes xAI's legacy Chat Completions endpoint (its wire protocol outranks npm metadata); Omni uses Responses, xAI's preferred API and the only one with encrypted reasoning. As with Ollama Cloud, changing catalog models' dialects takes code.
- **xAI `modify_body/4`.** Models with no effort data (`grok-4.20-0309-reasoning`, `grok-build-0.1`) reject `reasoning.effort` with any value, `"none"` included, so the module drops `reasoning` for them. It depends on the model's thinking data, so it isn't a provider-wide flag.

`anthropic-version` stays in the Anthropic module rather than a dialect header callback: other Anthropic-compatible endpoints ignore it and none require it.

### Provider ids

A provider's id is its catalog key, snake_cased: `:anthropic`, `:fireworks_ai`, `:ollama_cloud`. It is the single identity -- config keys, `get_model/2` lookup, and source catalog lookups all use it, and sources translate it to their own key format. There is no renaming and no separate catalog id. Two instances of one provider (two regions, two accounts) are not supported; call-site `host:` and `api_key:` cover those cases.

### Configuration

Two keys, with separate jobs: **`:models` selects** what loads, **`:providers` configures** by id. Configuring a provider never enables it, so "does setting compat turn a provider on?" has a plain answer: no. Disabling a built-in is listing `providers:` without `:builtins`.

```elixir
config :omni, :models,
  providers: [:builtins, :fireworks_ai, :gpu_box],   # default [:builtins]
  source: Omni.Sources.ModelsDev,
  filter: {MyApp.Models, :keep?}

config :omni, :providers,
  anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}],
  zai_coding_plan: [dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :zai]]}],
  ollama: [
    host: "http://gpu-box:11434",
    models: ["llama3.1:8b", [id: "qwen3.5:4b", context_size: 32_768, thinking: true]]
  ],
  openai: [
    models: [
      [id: "gpt-6", context_size: 1_000_000],   # corrects the catalog model
      [id: "ft:gpt-4o:acme::abc123", dialects: %{text: Omni.Dialects.OpenAIResponses}]
    ]
  ],
  gpu_box: [
    dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]},
    auth: :none,
    models: [[id: "llama-3.3-70b", dialects: %{text: Omni.Dialects.OpenAICompletions}]]
  ]
```

- **`:models` keys:** `providers` (ids; `:builtins` expands to every built-in and may sit in the list), `source`, `filter`.
- **`:providers` keys:** `name`, `host`, `api_key`, `auth`, `headers`, `dialects`, `module`, `models`, `source`. A module's `config/0` takes `name`, `api_key`, `auth`, `headers`, `dialects`; an endpoint under `dialects:` takes `base_url` and `compat`. Unknown keys are boot errors, including in entries for providers that aren't loaded.
- **Dialects are module names** in config. A user's own dialect works with no registration. String ids (`"openai_completions"`) are an internal detail for reading catalog data (`Omni.Dialect.get/1`).
- **`models:`** corrects or adds models (ids or `Model.new/1` keyword lists). An entry whose id the catalog has merges over the catalog model field by field (`dialects` by capability), so one field can be corrected without restating the rest; an entry with a new id adds a model, which names its dialect (or has the module's `models/2` stamp one). Entries in app config and in `load/1` opts for the same id merge too. A custom provider and local Ollama have nothing else. Removal is the filter's job.
- **`filter:`** is a predicate over each finished `%Model{}` (provider embedded), run at load, including config-defined models. It is `{Mod, :fun}` or a named capture, because anonymous functions don't survive compile-time config.
- **v1 config raises** at boot with a migration message: per-module keys (`config :omni, Omni.Providers.X`), the old `:providers` list, modules in `providers:`, `auth_header:`, provider-level `base_url:` (suggesting `host:` when the path matches the endpoint's, else the `dialects:` form naming the module; raised in `assemble/2`, where the endpoint is known), top-level `compat:`, and `dialects: %{text: Module}`.

**One merge rule.** A provider is built from three layers, later winning: source data ← module `config/0` ← app config (← call-site opts, at request time). Values without identity replace. Collections with identity merge shallowly by key: `headers` by header name, `dialects` by dialect module and then by field (`base_url` replaces, `compat` merges by flag), `models` by model id and then by field. Keyword lists in config are maps in disguise and are normalised before merging. Within compat, `omit` and `extra_body` values replace rather than merge.

### Endpoints

Each dialect a provider serves has an `%Omni.Provider.Endpoint{base_url, compat}`. `base_url` is the whole URL, and the request URL is one join, `endpoint.base_url <> dialect.handle_path(model, opts)` (a trailing slash on the base URL is trimmed). URLs are set in three places, each doing one thing:

| Where | Sets | When |
|---|---|---|
| `dialects: %{Mod => [base_url: url]}` | one endpoint's whole URL | load |
| provider `host:` (app config) | the origin of every endpoint URL from the source or the module | load |
| `host:` request option | the origin of this request's URL | request |

- **`host:` is an origin** -- scheme, host and port, no path -- and keeps each URL's path: `ollama: [host: "http://gpu:11434"]` sends chat to `http://gpu:11434/api/chat` and System One to `http://gpu:11434/v1/systemone`. It is the one knob for the common moves (another box, a region, a proxy on the same paths, Bypass in tests), and fills catalog URLs templated only in their origin (`https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1`; for a scheme-less template such as `${NEON_AI_GATEWAY_BASE_URL}/v1` the origin is the leading `${VAR}`). A value with a path raises at load and is `{:error, {:invalid_host, host}}` at the call site: if `host:` took a path it would be a base URL by another name, with the same ambiguity (`openai: [host: "http://localhost:4000/v1"]` would go to `/v1/v1/responses`). To change a path, set the endpoint's URL.
- **App config URLs are used as written.** The Loader applies provider `host:` to the source and module endpoints before app config's endpoints merge, so `host:` picks Alibaba's chat region while an explicit per-workspace URL on another endpoint stays put. The call-site `host:` overrides everything. `host:` is not stored on the struct.
- **There is no provider-level `base_url` and no call-site `base_url`.** Every case found fits `host:` or is clearer per endpoint. The one loss is changing a path for a single request, for which no use case was found; a path-changing gateway in front of a built-in (Cloudflare AI Gateway) is an endpoint URL in config.
- **Missing URLs fail at request time.** A provider loads with no URL for an endpoint (a catalog provider whose catalog has none, a custom provider still being configured). A request to it returns `{:error, {:no_base_url, dialect}}`, as does one to a URL still holding a placeholder after `host:`; a model whose dialect has no endpoint (only possible for a hand-built model) returns `{:error, {:no_endpoint, dialect}}`.
- **One URL per dialect.** When a catalog's models of one dialect disagree on the URL, the first by id wins and the rest are skipped with a warning. It is a limit of the design, accepted while only google-vertex (templated anyway) hits it.

*History: the first attempt split the URL into a provider `base_url` holding the shared host and a per-endpoint `path_prefix`. It made `base_url` mean the host (so `openai: [base_url: "http://localhost:4000/v1"]` went to `/v1/v1/responses`), needed code in sources to take catalog URLs apart, couldn't represent another host, and had three joins.*

### Assembly and loading

`Omni.Application` calls `Omni.Provider.Loader.boot/0` at startup, which validates app config and loads the selected providers synchronously, so models exist before any user code runs. The empty supervisor `start/2` returns is just the OTP contract. `Omni.Provider.load/1` loads more at runtime (ids, or `{id, opts}` with inline config); loading an id that is already loaded replaces its provider and models, and models obtained earlier keep the provider struct they were built with. Because config is baked in at load, changing it after boot means reloading.

For each provider id the Loader:

1. Resolves the module: config `module:`, else the built-in.
2. Fetches catalog data from the source: the provider with its endpoints, and the models. An id the catalog doesn't know starts empty.
3. Merges the provider: source ← module `config/0`, then applies `host:` to those endpoint URLs, then ← app config. Endpoints merge by dialect module, then by field; `like:` resolves within each layer.
4. Fills defaults (`auth: :dialect`, name from id) and validates: every endpoint's key is a dialect module, its compat flags pass the dialect's `compat_schema/0`, and `auth` is valid.
5. Merges config `models:` over source models by id (field by field; new ids are added), then passes them through the module's `models/2`.
6. Checks models. **Model data decides each model's dialect, and nothing fills one in.** A model with no dialect, or with a dialect the provider has no endpoint for, is skipped with a warning if it came from the catalog, and raises if config named it.
7. Stamps the provider onto every model, applies the filter, and stores.

`Loader.assemble/2` runs steps 1-7 without touching the store, which is what tests use. A load pass runs inside `Omni.Source.with_cache/1`, a pass-scoped cache (process dictionary): sources memoize shared expensive work (the ~9 MB decoded snapshot) with `Omni.Source.memo/2`, computed once per pass and garbage collected when it ends.

**Nothing is guessed.** A wrong dialect produces confusing errors far from the cause, so refusing beats defaulting. An earlier rule filled a dialect-less model from the provider's only text endpoint, or from the dialect its other models shared; it went once providers served several text dialects, since it guessed from whatever endpoints happened to exist (Cohere's one Completions model would have pulled its native-API models onto the compatibility endpoint). The data shows nothing is lost: models.dev's dialect-less models belong to providers needing a module or a new dialect anyway, and llm_db's are ones it marks `catalog_only`. llm_db and req_llm take the same line: llm_db applies provider-level defaults per operation only where it has curated them and marks the rest `catalog_only`; req_llm refuses those.

| Condition | Result |
|---|---|
| No endpoint URL (catalog has none, or provider is custom) | Not an error at load; a request returns `{:error, {:no_base_url, dialect}}` |
| Catalog model with no dialect, or one with no endpoint | Skipped with a warning |
| Config model with no dialect, or one with no endpoint | Raise |
| Unknown or invalid compat flag; `host:` with a path | Raise |
| v1-style config | Raise with migration message |
| No endpoints and no models | Warning |
| No API key | Not an error -- a key can be passed per request; a request without one returns `{:error, :no_api_key}` |

### Provider modules

A provider module declares `@behaviour Omni.Provider`. Every callback is optional and skipped when not defined:

| Callback | When | Purpose |
|---|---|---|
| `config/0` | Load | Keyword overrides over source data: name, key, auth, headers, and endpoints (URL and compat) under `dialects:` |
| `models/2` | Load | Receives the merged models (config entries included) and provider; returns the final list (Ollama, Ollama Cloud, OpenAI, TypeSafe, Venice, xAI) |
| `modify_body/4` | Request | `(body, model, input, opts)` after the dialect builds the body; `input` is the `%Context{}` or `%Decision{}` being sent, so matching on it picks the capability. Receives the model, so it can vary by model (Groq) |
| `modify_request/3` | Request | `(req, provider, opts)` last touch on the finished `%Req.Request{}`, after data auth. For signing, token fetches, query params. Returns `{:ok, req} \| {:error, reason}` because credentials can depend on external state |

The rule: **reach for compat flags first; module code is for what flags can't express**, such as a quirk only some of a provider's models have. There is no parse-side hook (`modify_deltas` was removed in v2): parse-side variation lives in the dialect.

### Rejected alternatives

- **Function hooks as struct fields** (`modify_body: &Mod.fun/3`). Keeps post-hoc rewriting, makes nothing expressible in config, and closures can't live in compile-time config.
- **A central quirk registry keyed by id or base URL** (Pi's auto-detect). Action at a distance; base URL matching breaks on region overrides.
- **A data table of built-ins instead of modules.** Modules give each built-in a moduledoc and a home for residual code; their `config/0` is the table, distributed.
- **Naming-enables config** (`fireworks_ai: []` turns the provider on). Conflates configuring with enabling and needs a separate mechanism to disable built-ins.
- **`api_key` as a list of candidates.** Only Google has genuine alternatives in the catalog; multiple variables almost always mean multi-part credentials.
- **Per-model compat.** What looked per-model resolves to model capability data, dialect routing, or module code (see [Where compat lives](#where-compat-lives)).
- **Lazy per-provider loading / a whole-catalog mode.** No real use case; `providers:` bounds the set.
- **An `Omni.Next` side-by-side namespace** for v2. The change reaches `Model`, `Request`, `Dialect` and `Source`; the v2 branch is the isolation.

---

## Dialects

### What a dialect is

A dialect is a module translating between Omni's types and the wire format of a family of APIs: it builds the request body and path, and reads what comes back. It is pure data transformation, with no knowledge of HTTP or configuration, no concept of where the API lives or who is calling, and it knows about providers only through the compat flags it declares. The separation exists because many providers share a wire format: the Chat Completions dialect is written and tested once, and each provider that speaks it is a struct with an endpoint (a URL and perhaps a few compat flags) and a key.

### Behaviours

`Omni.Dialect` is the base every dialect shares: `auth/0`, `compat_schema/0`, plus the registry (`get/1`, `get!/1`), `compat/2` and `capability/1`. The callbacks that build requests and read responses live in one behaviour per capability, `Omni.Dialect.Text` and `Omni.Dialect.Decision`. `use Omni.Dialect, :text` (or `:decision`) declares both behaviours and nothing more. A module serves exactly one capability (the callback names overlap, so it can't implement two); a provider serving both lists a dialect for each. `Omni.Dialect.capability/1` reads the declared behaviour, so a module without one is not a dialect and fails at load, and the Loader checks each model names each dialect under its own capability.

| Behaviour | Callback | Returns | Purpose |
|---|---|---|---|
| `Dialect` | `auth/0` | `:bearer \| {:header, name}` | The home API's key scheme, used when a provider's `auth` is `:dialect` |
| `Dialect` | `compat_schema/0` | `map()` | Peri schema of the compat flags the dialect understands (`%{}` for none) |
| both | `option_schema/0` | `map()` | Peri schema of dialect-specific options, merged with the capability's schema |
| both | `handle_path/2` | `String.t()` | Resource path for the model and opts, appended to the endpoint's `base_url` |
| both | `handle_body/3` | `map()` | The request body from the model, the `%Context{}` or `%Decision{}`, and validated options |
| `Text` | `handle_event/2` | `[delta]` | Parses one decoded stream event into delta tuples; receives the model |
| `Decision` | `handle_response/3` | `{:ok, Decision.t()} \| {:error, term}` | Reads the decoded JSON body into answers and usage (see [Decisions](#decisions)) |

**Encoding never fails.** Option validation happens at the API boundary before any dialect callback runs, so dialects receive validated options and operate on known-good data. `handle_event/2` returns a list (empty to skip). Request bodies are not validated at runtime; a malformed body is a library bug caught by tests. `handle_response/3` is the one callback returning a tuple: a whole response either matches the questions asked or doesn't.

### The dialects

| Module | String id | Capability | Home API | Auth |
|---|---|---|---|---|
| `OpenAICompletions` | `"openai_completions"` | text | OpenAI Chat Completions; spoken by most third-party providers | bearer |
| `OpenAIResponses` | `"openai_responses"` | text | OpenAI Responses | bearer |
| `AnthropicMessages` | `"anthropic_messages"` | text | Anthropic Messages | `x-api-key` |
| `GoogleGemini` | `"google_gemini"` | text | Gemini `streamGenerateContent` (model id in the path) | `x-goog-api-key` |
| `OllamaChat` | `"ollama_chat"` | text | Ollama native `/api/chat` (NDJSON) | bearer |
| `SystemOne` | `"systemone"` | decision | TypeSafe System One, `/systemone` | bearer |
| `OpenAIDecisions` | `"openai_decisions"` | decision | OpenAI Decisions, `/decisions` | bearer |

String ids exist for catalog data; `Omni.Dialect.get/1` resolves them. Config uses modules.

### Text callback details

**`handle_path/2`** -- returns the resource path. The version segment belongs to the endpoint's `base_url`:

```elixir
# Anthropic Messages
def handle_path(_model, _opts), do: "/messages"

# OpenAI Completions
def handle_path(_model, _opts), do: "/chat/completions"

# Google Gemini
def handle_path(%Model{id: id}, _opts), do: "/models/#{id}:streamGenerateContent?alt=sse"
```

**`handle_body/3`** -- receives a `%Model{}`, `%Context{}`, and the validated options map. This is where Omni's types become the native JSON structure -- messages are reshaped, content blocks are encoded, tools are serialized, options are mapped to API parameters, and compat flags (read with `Omni.Dialect.compat(model, __MODULE__)`) choose between spellings. Options already include defaults, so there is no need for fallback values.

**`handle_event/2`** -- receives a single decoded JSON event map and the model, and returns normalised delta tuples. It is stateless: one event in, deltas out, no accumulation. That keeps dialects trivially testable: give it a JSON map, assert the tuples. It receives the model for one reason: capturing data for replay is governed by a compat flag, so the dialect must see compat at parse time (see [Parsing](#parse-tolerantly-encode-by-flag)).

```elixir
def handle_event(%{"type" => "content_block_delta", "index" => idx,
                   "delta" => %{"type" => "text_delta", "text" => text}}, _model) do
  [{:block_delta, %{type: :text, index: idx, delta: text}}]
end
```

### Option validation

Options are validated once, early, in `Request.validate/3`. The schema is the config schema every capability shares (type-loose: `api_key`, `host`, `headers`, `plug`, `timeout`), plus the text schema for text requests (`max_tokens`, `temperature`, `thinking`, `cache`, `output`, `metadata`), merged with `dialect.option_schema/0`. The provider's `api_key` and `headers` are merged under the call-site opts first (the URL is read from the endpoint, not merged as an option), then the whole map is validated in one strict Peri pass (unknown keys rejected, catching typos). Loop options (`raw`, `max_steps`, `tool_timeout`) are taken by `Omni.Loop` before this, and `output` is read by both; `decide/3` pops `raw` itself. All downstream callbacks receive the one validated map.

### Compat flags

Compat flags describe how a provider deviates from the API its dialect is named after. They are the main mechanism for provider variation, and dialects are their single home.

#### Rules

- **No flag means the home API's behaviour.** With no flags, the Completions dialect behaves exactly like OpenAI's own Chat Completions API. A flag exists only to describe a deviation. No flag takes `nil`; absence is the default. A catalog provider "speaks the dialect plain": no flags.
- **Named by wire shape or Omni concept, never by provider.** If two providers share a shape they share a value. Declaring something "the Z.ai way" when Moonshot does the same thing is a claim Omni has no standing to make.
- **Four kinds of flag**, distinguished by name pattern and value type:

  | Kind | Name | Value | Reads as |
  |---|---|---|---|
  | Rename | `<subject>_field` | string: literal wire path, dots for nesting | "put it here instead" |
  | Reshape | `<subject>_format` | atom: a named shape the dialect documents | "use this shape instead" |
  | Drop | `omit` | list of atoms naming Omni concepts | "don't send these" |
  | Add | `extra_body` | string-keyed map of literal wire fields | "also send these" |

  Omni's vocabulary where Omni has the concept (`thinking`, `output`, `attachment`, `max_tokens`); literal wire text where it doesn't. A string value is always literal wire text; an atom is always a named thing the dialect validates. `_format` enums include the home value (`output_format: :json_schema`) so a borrowed flag can be reset.
- **Flat, with a shared prefix, not nested.** Compat merges per flag; nesting would force a deep merge or let one user key wipe out a borrowed `like:` set.
- **`omit`, not a generic `drop_fields`.** `omit` is a validated list of things the dialect knows how to remove wherever they sit (strict schemas sit three levels deep), so a typo fails at boot. It also gives a future warning mechanism its sentence for free: "this provider ignores `:cache`".
- **Ship rule.** A flag ships only with a built-in provider that uses it, proven by verify against that provider's live API. Prior art says which flags to expect; only a live endpoint proves a flag works. The flag set grows with the built-in list, not ahead of it.

The Completions flag table, with what each value does on the wire, is in the `Omni.Dialects.OpenAICompletions` moduledoc. The other six dialects have empty `compat_schema/0`s: no built-in needs a flag on them yet. That is the ship rule, not a claim that catalog providers speaking them need nothing.

#### Built-in flags

All on `Omni.Dialects.OpenAICompletions`. Anthropic, Google, OpenAI, TypeSafe, xAI and both Ollamas set none.

| Provider | Flags | Why |
|---|---|---|
| Alibaba | `thinking_toggle_format: :enable_thinking`, `thinking_budget_field: "thinking_budget"`, `thinking_replay_format: :reasoning_content`, `output_format: :json_object` | Switches thinking with `enable_thinking` and takes a budget; reasoning goes back in the field it arrives in; strict `json_schema` is turned into JSON mode server-side and then fails, so JSON mode with the schema in the prompt is used |
| Groq | `thinking_replay_format: :reasoning` | Reasoning arrives in `reasoning` and goes back there (req_llm strips `reasoning_content` for Groq, which rejects it) |
| Mistral | `max_tokens_field: "max_tokens"`, `thinking_replay_format: :content_chunks` | No `max_completion_tokens`; reasoning streams as thinking chunks in `content`, and Mistral asks for them back at the head of the assistant message. The chunk replay was verified through OpenCode Zen, which passes Mistral's wire through: the free tier serves no reasoning model |
| Moonshot | `thinking_toggle_format: :thinking_type`, `thinking_replay_format: :reasoning_content` | `thinking: {type: ...}` on toggle models. `max_completion_tokens` is honoured. Tool loops pass without reasoning sent back, but Kimi's docs ask for it |
| NearAI | `max_tokens_field: "max_tokens"`, `omit: [:cache, :thinking, :strict_schema]` | Ported from v1; not verified live (no key) |
| OpenCode | `thinking_replay_format: :reasoning_content` (keyed by Completions) | Zen's GLM, Kimi and DeepSeek models take reasoning in `reasoning_content`. Mistral models (`mistral-*`) take it as a leading thinking chunk, which `modify_body/4` makes from the field: Zen passes Mistral's wire through, and Mistral rejects unknown fields |
| OpenRouter | `thinking_effort_field: "reasoning.effort"`, `thinking_replay_format: :reasoning_details` | Nested effort; `reasoning_details` must round-trip in multi-turn |
| Together | `max_tokens_field: "max_tokens"`, `thinking_toggle_format: :reasoning_enabled`, `thinking_replay_format: :reasoning`, `omit: [:cache]` | No `max_completion_tokens`; reasoning arrives in `reasoning`, and Together's docs ask for it back in the field it arrived in; hybrid models switch with `reasoning: {enabled: ...}` (`reasoning_effort` takes no `"none"`); caching is automatic, with no retention field |
| Venice | `thinking_toggle_format: :reasoning_enabled`, `thinking_replay_format: :reasoning_content` | Venice recommends `reasoning: {enabled: false}` over `reasoning_effort: "none"`; reasoning goes back in the field it arrives in |
| Z.ai | `max_tokens_field: "max_tokens"`, `thinking_toggle_format: :thinking_type`, `thinking_replay_format: :reasoning_content`, `output_format: :json_object`, `attachment_format: :file_url` | Ignores `max_completion_tokens`; reasoning goes back in the field it arrives in, which Z.ai uses within a tool loop (by default, `clear_thinking` drops it from earlier turns); no JSON Schema constraints; files as `file_url` parts |

`like: :zai`, under a dialect, copies that dialect's flags from a built-in; the layer's own flags overlay it. It copies compat only -- not module, URL or key.

#### Where compat lives

Compat lives on the provider's endpoints, one set per dialect. Models carry no compat; they pick a dialect per capability, and the dialect reads that endpoint's flags:

```elixir
compat = model.provider.dialects[model.dialects.text].compat   # what Dialect.compat/2 does
```

This handles every provider shape with no special case: a single-dialect provider has one endpoint; a gateway (OpenCode) has one per dialect its models speak; a decision dialect is one more endpoint. In config, flags always go under their dialect: `dialects: %{Mod => [compat: [...]]}`.

Per-model compat was ruled out because what looked like per-model variation resolves elsewhere:

| Variation | Resolved by |
|---|---|
| Effort levels differ per model (Groq); effort vs toggle models on one provider (Moonshot, Z.ai, Alibaba) | Model capability data (`Model.thinking`) |
| One model needs another dialect's wire shape (OpenRouter's `anthropic/*` cache control) | Routing that model over a different dialect (not yet built) |
| Anything genuinely per-model that remains | Module code, which sees the model (Groq `modify_body/4`) |

The cost: `extra_body` is provider-wide and unconditional. A field only some models accept is module code.

#### Parse tolerantly, encode by flag

No library surveyed uses flags to parse Completions streams, and Omni doesn't either. The Completions parser is a union: `reasoning_content` or `reasoning`, `content` as a string or a list of thinking and text chunks (Mistral), tool calls with or without `index` and with arguments as a string or an object (Mistral), every known finish reason (including Z.ai's, Mistral's and Together's), cached tokens under `prompt_tokens_details` or flat on `usage` (Together), packed chunks (Venice), in-stream errors. All variation is on the encode side.

The one parse-side read of compat is capture for replay: with `thinking_replay_format: :reasoning_details`, the dialect stashes `reasoning_details` into `Message.private` while parsing and sends them back on that assistant message when encoding. Capture and replay share the flag, so data is only collected when it will be sent back. That is why `handle_event/2` receives the model. The other replay values need no capture: `:reasoning_content` and `:reasoning` send the message's thinking text in that field, and `:content_chunks` as a leading chunk.

Not adopted: replaying reasoning in the field it arrived in (pi). The flag lets the receiving API decide the shape, so a history from one provider never sends another's field to an API that rejects unknown fields (Mistral, Groq). Nor are the switches that keep reasoning from earlier turns (Z.ai `clear_thinking: false`, Alibaba `preserve_thinking: true`, Together's `chat_template_kwargs`) sent: they trade input tokens for continuity, a choice left to users: `extra_body`, or module code where the switch nests inside a field Omni sets (Z.ai's sits in `thinking`, and `extra_body` merges shallowly). Without them, providers use replayed reasoning within a tool loop, which is where it matters most.

Not adopted: a stateful parse hook (init, per-event state, flush) for reasoning streamed inline as `<think>` tags. No built-in needs it.

### Thinking

The `:thinking` option is translated per model, from capability data, not from model-name prefixes. Every library surveyed that models reasoning limits well splits *how an endpoint spells reasoning* (wire format -- dialect and compat) from *which levels a model accepts* (a fact about the model -- model data). Libraries that hard-code model-id patterns call that their weak spot.

#### Model data

`Model.thinking` is `false | true | %{efforts, toggle, budget}`, filled by sources from models.dev `reasoning_options` (`{type: "effort", values}`, `{type: "toggle"}`, `{type: "budget_tokens", min, max}`); llm_db passes those through and falls back to OpenRouter's `supported_efforts`.

- `:efforts` -- the values the model takes, as **wire strings** (`"none"`, `"minimal"`, `"default"`, `"low"`, ...), never atoms. `"none"` means it can be switched off.
- `:toggle` -- `true` when thinking switches on and off as a whole.
- `:budget` -- `{min, max}` when the model takes a token budget; either bound may be `nil`.
- `true` means the model reasons and nothing more is known (the catalog's empty list normalises to `true`); dialects fall back to their plain encoding.

#### Resolution (`Omni.Dialect.Thinking`)

Shared by the five text dialects and public, so custom dialects agree too. `resolve(model, option)` returns:

- `nil` -- send nothing: option unset, model doesn't reason, or off requested on a model whose data shows no way to switch off.
- `:off` -- switch off (toggle, `"none"` in efforts, or no data).
- `%{level, effort, budget}` -- on. `effort` is the model's value for the level, or `nil` with no effort list. `budget` is set when the model has a budget range or no data at all.

Rules:

- **`true` is `:medium`**, the same request a dialect builds for `:medium`.
- **One ladder:** `minimal < low < medium < high < xhigh < max`. A level clamps to the model's efforts: round up to the nearest supported value, else down. On never crosses into off.
- **`"default"`** is sent for any "on" request when it is the model's only "on" value (Groq Qwen).
- **Budgets** come from one table -- low 1024, medium 4096, high 16384, xhigh 24576, max 32768 -- clamped to the model's range. `%{effort:, budget:}` sets an exact budget, on budget models only; elsewhere its effort applies.

#### Per-dialect encoding

| Dialect | Encoding |
|---|---|
| OpenAI Completions | **Off:** the `thinking_toggle_format` spelling if set, else `"none"` at `thinking_effort_field`. **On, model has efforts:** the effort at `thinking_effort_field`, even when a toggle format is set. **On, no efforts:** the toggle if set (plus a budget at `thinking_budget_field` when set and the model takes one), else the level's effort string. `omit: [:thinking]` sends nothing |
| OpenAI Responses | `reasoning.effort` (clamped), `"none"` for off, `summary: "auto"`. With no data, `:max` sends `"xhigh"` |
| Anthropic Messages | **Efforts and no budget range** (Claude 5, Opus 4.7+): adaptive (`thinking.type: "adaptive"` plus `output_config.effort`). **Budget range, or no data:** `enabled` with `budget_tokens`, added to `max_tokens`. **Off:** `disabled`. Temperature is dropped when thinking is on |
| Google Gemini | **Efforts** (Gemini 3): `thinkingLevel` matched by name. **Budget or no data** (Gemini 2.5): `thinkingBudget`. **Off:** `thinkingBudget: 0`, only where the model can be switched off |
| Ollama Chat | **Efforts:** the clamped string. **Toggle or no data:** boolean |

Not adopted: a dynamic mode (`true` meaning "on, the model decides"). On current models adapting is how thinking works, not a mode to switch on: Claude 4.6+ adaptive thinking and Gemini 3 take the effort as a guide, and OpenAI models choose within an effort. Only Gemini 2.5 (`thinkingBudget: -1`) has a separate dynamic setting. Sending no level where an API allows it handed users the provider's default (`high` on Claude and Gemini 3) on some models and Omni's `:medium` on others, so `true` is one Omni default instead. Prior art has no cross-provider dynamic value either: pi takes levels only, ai-sdk's `'provider-default'` sends nothing (Omni's unset), and req_llm's `:default` sends adaptive with `"medium"` on Anthropic and nothing on OpenAI.

Older models need not be perfect: Opus 4.5 and 4.6 moved from adaptive to budget thinking when their hard-coded prefix list went. Anthropic's `@strict_sampling_prefixes` (Opus 4.7 rejects non-default sampling) is unrelated to thinking and stays.

### Testability

Each layer is testable independently:

```elixir
# A dialect in pure isolation -- no HTTP, no provider store
body = AnthropicMessages.handle_body(model, context, opts)
assert body["messages"] == [...]

deltas = AnthropicMessages.handle_event(%{"type" => "content_block_delta", ...}, model)
assert deltas == [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}]

# A compat flag: build a model whose provider's endpoint carries it
model = Fixtures.model(provider: [compat: %{max_tokens_field: "max_tokens"}])
assert OpenAICompletions.handle_body(model, context, opts)["max_tokens"] == 4096

# Provider assembly without touching the store
{provider, models} = Omni.Provider.Loader.assemble(:zai)

# The full stack, against a Req.Test stub
{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, "Hi", plug: {Req.Test, MyStub})
```

The dialect is pure functions (maps in, maps out). Providers are data. The top-level API composes them.

---

## Messages & Response

### Message struct

A message is a single struct for both roles -- `:user` and `:assistant`. There are no role-specific struct types (`%UserMessage{}`, `%AssistantMessage{}`, etc.) because the structural differences between roles live in the **content blocks**, not in the message envelope. A user message contains text and attachment blocks; an assistant message contains text and tool use blocks. The message wrapper is the same shape every time.

Pattern matching on `%Message{role: :assistant}` is just as expressive as a separate struct, and means every function operating on message lists handles a single type.

```elixir
defmodule Omni.Message do
  defstruct [
    :role,            # :user | :assistant
    content: [],      # list of content blocks
    timestamp: nil,   # DateTime, local metadata -- not from the API
    origin: nil,      # %{model: {provider_id, model_id}, dialect: module} on assistant messages Omni produced
    private: %{}      # provider-specific opaque round-trip data
  ]

  def new(attrs) do
    struct!(__MODULE__, Map.put_new_lazy(attrs, :timestamp, &now/0))
  end

  defp now, do: DateTime.utc_now()
end
```

`private` holds data a dialect captures while parsing and must send back when encoding the same message later -- OpenRouter's `reasoning_details` is the current example. Keys are flat atoms; dialects write and read them, users don't. Provider-specific data goes here, not on content blocks.

`origin` records which model wrote an assistant message and the dialect it spoke. `StreamingResponse` stamps it; user messages, and messages built by hand, have none. `Codec` writes it readably (`%{"model" => "provider/model", "dialect" => "Omni.Dialects.AnthropicMessages"}`), and a provider or dialect unknown to the decoding node decodes as `nil`. It is a field, not a `private` key, because Omni core writes and reads it (dialects don't), and because "which model wrote this" is useful to users too.

#### Replay across models

Thinking, signatures and `private` go back only to the provider and dialect that produced them. Before the dialect encodes, `Request.build/3` strips every assistant message whose origin differs from the target's provider or dialect, or is `nil`: thinking blocks are dropped, `signature` is cleared on text and tool uses, `private` is emptied, and a message left with no content is dropped. Text and tool uses always go through. Within one provider and dialect everything is sent, whatever the model: Anthropic, OpenAI and Google document that their APIs drop reasoning the target model can't read, and OpenRouter does the same across its upstreams.

Why both keys: another provider's signatures fail validation (OpenAI's encrypted reasoning sent to Anthropic: `Invalid signature in thinking block`), and the dialect matters on multi-dialect gateways (OpenCode Zen's GPT reasoning sent to its Claude models fails the same way). Readable thinking from another provider is dropped too, rather than sent as reasoning to Completions providers that would take it, so there is one rule; turning it into visible text (pi's old behaviour) makes the new model write its reasoning into the answer. pi drops thinking from any other model, keyed by model; ai-sdk and req_llm key by provider. Keying by model would lose continuity on a switch within one provider, against Anthropic's guidance to keep sending blocks unchanged.

What the target then needs, the dialect fills: Anthropic never sends a thinking block without a signature (a stream cut off mid-block), and Gemini puts Google's `skip_thought_signature_validator` sentinel on the first unsigned tool use of each step in the current turn (from the last user message that isn't only tool results), since Gemini 3 rejects an unsigned function call there. Anthropic's adaptive mode doesn't require leading thinking on a tool-use turn, so a foreign tool loop continues there without one.

Verified live with a one-off script (2026-10-28): every same-provider switch tested passed unchanged (Haiku 5.5 to Opus 5.5, gpt-6-luna to astra, Gemini 3.8 Flash and 3.5 Flash-Lite both ways, grok-4.3 to 4.7, OpenRouter Claude, GPT and Gemini); foreign thinking failed on Claude and passed once dropped, mid tool loop too; Gemini 3 needed the sentinel, literal or base64.

**Why structs, not plain maps?** Structs give field validation at construction time, better documentation through typespecs, and pattern matching on the struct name. A typo like `%{roles: :user}` silently passes with maps; `%Message{roles: :user}` blows up at compile time.

**Why not Elixir Records?** Records are an Erlang-ism almost never used in Elixir userland. They'd confuse users with no meaningful upside over structs.

### Two roles, not three

Most providers (OpenAI, Google, etc.) treat tool results as a distinct message role (`:tool`). Omni does not. Tool results are content blocks within user messages, following the pattern established by Anthropic's API.

This is a better fit for Omni's design because:

- **The Message struct stays minimal.** No fields that only exist for one role (like `tool_use_id` or `tool_name`). All role-specific data lives in content blocks where it belongs.
- **Content blocks are the right level of abstraction.** We already decided that role differences are expressed through content blocks. Tool results fit that principle -- they're a *kind of content* in a user turn, not a fundamentally different kind of message.
- **It's semantically accurate.** A tool result is the user's application reporting back to the model. It's a user turn with structured content, not a message from a third party called "tool".
- **Multi-content turns are natural.** Tool results mixed with text comments, or multiple results from parallel tool uses, are just a list of content blocks in one user message. No message ordering rules needed.

The dialect work is equivalent either way -- if we used three roles, the Anthropic dialect would need to merge tool messages into user messages. With two roles, the OpenAI dialect scans user messages for tool result blocks and emits them as separate tool-role messages on the wire. The dialect is already doing substantial transformation; this is the same kind of work.

A tool use conversation looks like:

```elixir
[
  %Message{role: :user, content: [
    %Content.Text{text: "What's the weather in London?"}
  ]},
  %Message{role: :assistant, content: [
    %Content.ToolUse{id: "call_123", name: "weather", input: %{city: "London"}}
  ]},
  %Message{role: :user, content: [
    %Content.ToolResult{tool_use_id: "call_123", name: "weather",
                        content: [%Content.Text{text: "15C, cloudy"}]}
  ]},
  %Message{role: :assistant, content: [
    %Content.Text{text: "It's currently 15C and cloudy in London."}
  ]}
]
```

### Timestamps

Messages carry an optional `timestamp` field. This is **local metadata** -- it records when the struct was created, not data from the provider API. Dialects ignore it when building requests.

The `Message.new/1` constructor defaults the timestamp via a lazy function, so messages are automatically stamped when created through the normal path, but the field isn't required when constructing messages in tests or from raw data.

### Response struct

`generate_text` returns a `%Response{}` that wraps a message rather than duplicating its fields. The response is an envelope containing the message plus generation metadata.

```elixir
defmodule Omni.Response do
  defstruct [
    :message,       # %Message{role: :assistant, content: [...]}
    :model,         # %Model{} -- the model that generated this response
    :usage,         # %Usage{} -- token counts and computed costs
    :stop_reason,   # :stop | :length | :tool_use | :refusal | :cancelled | :error
    :error,         # nil | error description when stop_reason is :error
    :raw,           # nil | [{%Req.Request{}, %Req.Response{}}], one per step
    :output,        # nil | map -- validated/decoded structured output
    messages: [],   # [%Message{}] -- all messages from multi-step generation (populated by Loop)
    usage: %Usage{} # cumulative across steps
  ]
end
```

**Composition over flattening:** Because the response contains a fully-formed `%Message{}`, appending to a conversation thread is straightforward:

```elixir
response = Omni.generate_text(model, context)

# Push the message onto the context
context = Context.push(context, response.message)

# Or push the response: every message from a multi-step generation is added
context = Context.push(context, response)
```

No conversion step is needed -- the message was never disassembled.

**Stop reason is response metadata, not conversation data.** The stop reason doesn't need to be carried in the message sequence. If the model stopped because of a tool use, there will be a tool use content block in the message's content list -- that block is what tells the conversation "this turn used a tool", and it's what dialects look at when building the next request. The stop reason is metadata *about* the generation event, redundant with the content blocks for conversation purposes.

### Raw request/response access

The raw Req request and response are available for debugging by passing `raw: true` in options:

```elixir
{:ok, response} = Omni.generate_text(model, context, raw: true)
[{req, res} | _] = response.raw
```

The `raw` field is `nil` by default and populated with a list of `{%Req.Request{}, %Req.Response{}}` tuples when requested -- one per step of a tool loop. The raw Req structs are stored directly -- the point of the escape hatch is access to what actually happened on the wire, not another abstraction layer over it.

Because request building (`Request.build/3`) is separated from execution (`Request.stream/3`), both the `%Req.Request{}` and `%Req.Response{}` are naturally available to the orchestration layer. The `StreamingResponse` struct holds both when `raw: true` is passed, and they are attached to the final `%Response{}` when the stream completes.

### Naming rationale

`%Response{}` is deliberately simple. If future generation types are added (image, audio), they would use distinct types (e.g. `%ImageResponse{}`) because their inputs and outputs are structurally different -- not just parameterically different. There's no need to pre-generalise the name for features that don't exist yet; renaming a struct is one of the cheaper refactors in Elixir.

---

## Usage

### Usage struct

`%Usage{}` tracks token counts and computed costs for a generation request. Costs are calculated automatically from the model's pricing data and the token counts returned by the provider.

```elixir
defmodule Omni.Usage do
  defstruct [
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    total_tokens: 0,
    input_cost: 0.0,
    output_cost: 0.0,
    cache_read_cost: 0.0,
    cache_write_cost: 0.0,
    total_cost: 0.0
  ]
end
```

Token counts are extracted from the provider's API response. Costs are derived by multiplying token counts against the pricing data on the `%Model{}` struct (cost per million tokens for each tier), in `Usage.price/2`, shared by `StreamingResponse` and `Request.send/4`. `input_tokens` excludes cached tokens on every dialect; they are `cache_read_tokens`, priced at the cache rate.

**Why flat rather than nested maps?** A nested shape like `%Usage{tokens: %{input: 0}, cost: %{input: 0}}` loses struct-level field validation on the inner maps -- a typo like `usage.tokens.imput` silently returns `nil`. The flat shape gives compile-time safety on every field, consistent with the design principle used throughout the library.

### Accumulation

The `Usage` module provides `add/2` and `sum/1` for summing usage across requests -- the loop uses them to make `response.usage` cumulative across steps, and they're useful for tracking spend:

```elixir
total_usage = responses |> Enum.map(& &1.usage) |> Usage.sum()
```

---

## Tools

### Tool struct

A tool is a data struct describing a function the model can use. The struct carries everything the dialect needs to serialize the tool definition, plus an optional handler for execution.

```elixir
defmodule Omni.Tool do
  defstruct [
    :name,           # Tool name string
    :description,    # Human-readable description for the model
    :input_schema,   # JSON Schema map OR {Adapter, state} tuple
    :handler         # nil | (map -> any) -- local metadata, ignored by dialects
  ]
end
```

The `input_schema` field holds a JSON Schema map -- the universal wire format every provider accepts -- or an `Omni.Schema.Adapter` tuple `{module, state}` that wraps a custom validator (see [Custom schema validators](#custom-schema-validators) below). The name `input_schema` is used over `parameters` for consistency with `ToolUse.input` (the tool defines its `input_schema`, the model returns `input` conforming to that schema) and to avoid OpenAI's baggage where parameters was nested under a `function` wrapper.

The `handler` field is local metadata, like `timestamp` on messages -- it exists for the user's convenience and is ignored by dialects when serializing tool definitions. If present, it's a single-arity function `(map -> any)` that executes the tool given the model's input.

### Schema helpers

Raw JSON Schema is verbose and error-prone. `Omni.Schema` provides plain builder functions that return standard JSON Schema maps:

```elixir
defmodule Omni.Schema do
  @behaviour Omni.Schema.Adapter

  # Builders
  def object(properties, opts \\ [])
  def string(opts \\ [])
  def number(opts \\ [])
  def integer(opts \\ [])
  def boolean(opts \\ [])
  def array(items, opts \\ [])
  def enum(values, opts \\ [])
  def any_of(schemas, opts \\ [])
  def update(schema, opts)

  # Adapter dispatch (also implements Omni.Schema.Adapter for raw maps)
  def to_schema(schema_or_tuple)
  def validate(schema_or_tuple, input)
end
```

Used with import:

```elixir
import Omni.Schema

input_schema = object(%{
  city: string(description: "The city name"),
  units: enum(["celsius", "fahrenheit"])
}, required: [:city])
```

Option keywords accept snake_case and are normalized to camelCase JSON Schema keywords automatically (e.g. `min_length:` becomes `minLength`). Keys without a known mapping pass through unchanged.

`validate/2` accepts either a raw schema map or an `Omni.Schema.Adapter` tuple. For raw maps it runs the built-in validator (Peri-backed via `Peri.from_json_schema/1`), enforcing types, required fields, all standard string/numeric/array constraints (including `multipleOf`, `minItems`, `maxItems`, `uniqueItems`), `enum`, `const`, union types, and `anyOf`/`oneOf`/`allOf` combinators. For adapter tuples it dispatches to the adapter's `validate/2`. Returns `{:ok, validated} | {:error, String.t()}` -- the error is a pre-formatted human-readable string ready to send back to the model on retry or surface as a tool result.

`to_schema/1` extracts the wire-form JSON Schema map. For raw maps it's identity; for adapter tuples it calls the adapter's `to_schema/1`. Dialects call this before emitting the schema in the request body so adapter-wrapped schemas serialize correctly.

These are plain functions returning maps -- no macros, no special types, no compilation step. Developers who already have JSON Schema maps (from OpenAPI specs, existing code) pass them directly. The dialect doesn't know or care which path produced the map.

### Custom schema validators

The built-in `Omni.Schema` validator is "good enough" for the common LLM-driven cases. For richer semantics -- `$ref` resolution, draft-2020-12 strict compliance, custom casting -- implement the `Omni.Schema.Adapter` behaviour and pass `{module, state}` anywhere a schema is accepted (`:output` option, `Tool.input_schema`, the `schema/0` callback in tool modules):

```elixir
@callback to_schema(state :: term()) :: map()
@callback validate(state :: term(), input :: term()) ::
            {:ok, term()} | {:error, String.t()}
```

This keeps Omni dependency-light while letting users plug in libraries like JSV. `Omni.Schema` itself implements the behaviour, so the dispatch is uniform: every schema is conceptually `{Adapter, state}`, with raw maps hitting `Omni.Schema` as the default adapter.

### Building tools inline

Tools can be built as plain structs, with or without handlers:

```elixir
# Without handler -- just data for the model
tool = %Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  input_schema: object(%{
    city: string(description: "The city name")
  }, required: [:city])
}

# With handler -- executable
tool = %Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  input_schema: object(%{city: string()}, required: [:city]),
  handler: fn input -> WeatherAPI.get(input["city"]) end
}
```

Inline handlers can capture external state via closures:

```elixir
user_ages = %{"joe" => 42, "alice" => 37}

tool = %Tool{
  name: "get_age",
  description: "Get a user's age by name",
  input_schema: object(%{name: string()}, required: [:name]),
  handler: fn input -> Map.get(user_ages, input["name"]) end
}
```

### Tool modules

For reusable, self-contained tools, the `Omni.Tool` behaviour and `use Omni.Tool` macro provide a module-based pattern. Name and description are passed as arguments to `use` (they're static configuration, not behaviour), while `schema/0,1`, `description/0,1`, `init/1`, and `call/1,2` are callbacks:

```elixir
defmodule MyWeatherTool do
  use Omni.Tool,
    name: "get_weather",
    description: "Get current weather for a city"

  @impl true
  def schema do
    import Omni.Schema
    object(%{
      city: string(description: "The city name"),
      units: enum(["celsius", "fahrenheit"])
    }, required: [:city])
  end

  @impl true
  def call(input) do
    WeatherAPI.get(input.city, input.units)
  end
end
```

The `name:` and `description:` options are optional shorthand — when provided, the macro generates default `name/0` and `description/0` callbacks. When omitted, the module must implement `name/0` directly; `description/0` may be omitted as long as `description/1` is implemented (the macro generates a raising default for `description/0`, mirroring the `call/1,2` pattern). The same applies to `schema/0,1`: implement either arity. The macro also generates `new/0` and `new/1` constructors that produce a `%Tool{}` struct:

```elixir
tool = MyWeatherTool.new()
```

The generated `new` function builds the struct and wires the handler:

```elixir
# Generated by use Omni.Tool
def new(args \\ nil) do
  state = init(args)
  %Tool{
    name: name(),
    description: description(state),
    input_schema: schema(state),
    handler: fn input -> call(input, state) end
  }
end
```

### Stateful tools

Tool modules support an `init/1` callback for tools that need external state. The default implementation returns `nil`. When overridden, it receives arguments passed to `new/1` and returns state that is passed as the second argument to `call/2`:

```elixir
defmodule AgeTool do
  use Omni.Tool,
    name: "get_age",
    description: "Get a user's age by name"

  @impl true
  def schema do
    import Omni.Schema
    object(%{name: string()}, required: [:name])
  end

  @impl true
  def init(age_map) when is_map(age_map), do: age_map

  @impl true
  def call(input, age_map) do
    Map.get(age_map, input.name)
  end
end

tool = AgeTool.new(%{"joe" => 42, "alice" => 37})
```

The `init/1` callback is the place to validate and fail early -- at tool construction time rather than mid-conversation when the model tries to use the tool.

For stateless tools, `call/2` has a default implementation that delegates to `call/1`, so authors can ignore opts entirely.

### Dynamic descriptions and schemas

`description/1` and `schema/1` both receive the state from `init/1` and return the values used in the `%Tool{}` struct. Their defaults delegate to the 0-arity versions. Override `description/1` to inject runtime context into the description (for example, environment-specific prompt fragments). Override `schema/1` when the input schema itself depends on state — for example, populating an `enum` of allowed values from configuration or a database lookup performed in `init/1`.

### Tool execution

`Omni.Tool.execute/2` validates input against the tool's schema and dispatches to the handler:

```elixir
{:ok, result} = Omni.Tool.execute(tool, tool_use.input)
```

If the tool has an `input_schema`, the LLM's string-keyed input is validated via `Omni.Schema.validate/2` and cast to match the schema's key types -- handlers receive atom keys when the schema uses atoms (built-in validator) or whatever shape the adapter returns. Returns `{:ok, result}` on success, `{:error, message}` on validation failure with a pre-formatted error string. Direct handler calls (`tool.handler.(input)`) bypass validation.

### How tools reach the context

Context always holds `[%Tool{}]` structs. How they're built is up to the developer:

```elixir
context = %Context{
  system: "You are a helpful assistant",
  messages: messages,
  tools: [
    MyWeatherTool.new(),
    AgeTool.new(age_data),
    %Tool{name: "ping", description: "Returns pong",
          input_schema: object(%{}), handler: fn _ -> "pong" end}
  ]
}
```

---

## Content Blocks

Content blocks are the core data types that live inside a message's `content` list. Each block type is a separate struct under the `Omni.Content` namespace. The structural differences between user and assistant messages are expressed entirely through which content blocks they contain.

Structs are used rather than maps because each block type has genuinely different fields, pattern matching on struct names gives compile-time safety (a typo like `%ToolUs{}` fails at compile time, whereas `%{type: :tool_us}` silently matches nothing), and each struct module provides a natural home for block-specific helpers and constructors.

### Text

```elixir
defmodule Omni.Content.Text do
  defstruct [:text, :signature]
end
```

The most common content block. The `signature` field is optional -- the OpenAI Responses API includes a hash of the text content for verification purposes. Most providers don't populate it.

### Thinking

```elixir
defmodule Omni.Content.Thinking do
  defstruct [:text, :signature, :redacted_data, :id]
end
```

Represents a model's reasoning/thinking output. The `signature` field is used by Anthropic to verify thinking block authenticity when they're passed back in multi-turn conversations. `redacted_data` holds Anthropic's encrypted redacted thinking, which must be sent back verbatim; when it is present, `text` is `nil`. `id` names the block for APIs that refer to reasoning by id on replay: an OpenAI Responses reasoning item keeps its id here, its summary as `text` and its encrypted content as `signature`.

### Attachment

```elixir
defmodule Omni.Content.Attachment do
  defstruct [:source, :media_type, meta: %{}]
end
```

A generic attachment type that handles images, PDFs, audio, and any future binary content types. The dialect determines how to encode the attachment based on `media_type`, and rejects unsupported types with a clear error.

The `source` field uses tagged tuples to represent the source type:

- `{:base64, binary}` -- base64-encoded data
- `{:url, url_string}` -- a URL reference

This makes the source type and data inseparable -- you can't accidentally construct an attachment with a URL source type but binary data. It also pattern matches cleanly in dialect implementations:

```elixir
defp encode_source({:base64, data}), do: %{"type" => "base64", "data" => data}
defp encode_source({:url, url}), do: %{"type" => "url", "url" => url}
```

The `media_type` field uses the technically correct "media type" terminology (per IANA) rather than the colloquial "MIME type". This also aligns with Anthropic's API field naming.

The `meta` map is an application-layer field that Omni's dialects do not read or send to providers. It provides a place for applications to associate their own data with attachments — for example, filenames or display labels in a UI.

```elixir
# Image with URL
%Attachment{
  source: {:url, "https://example.com/chart.png"},
  media_type: "image/png"
}

# PDF from base64
%Attachment{
  source: {:base64, pdf_data},
  media_type: "application/pdf"
}

# Image with application metadata
%Attachment{
  source: {:base64, image_data},
  media_type: "image/jpeg",
  meta: %{filename: "photo.jpg"}
}
```

### ToolUse

```elixir
defmodule Omni.Content.ToolUse do
  defstruct [:id, :name, :input, :signature]
end
```

Represents the model requesting a tool use. The `id` is a provider-generated identifier that links the use to its result. The `name` is the tool/function name. The `input` is a map of arguments -- always a parsed map, never a raw JSON string (the dialect handles parsing).

The `signature` field is optional, included for any provider that attaches verification data to tool uses (e.g. Gemini).

**Signature round-tripping:** The `signature` field on Text, Thinking, and ToolUse blocks exists because some providers require these values to be sent back in multi-turn conversations. When a dialect builds a request body, it must include signatures from previous turns if they are present. This is a dialect concern -- signatures are received from the provider in responses, stored on content blocks, and round-tripped back in subsequent requests.

```elixir
%ToolUse{
  id: "call_abc123",
  name: "get_weather",
  input: %{"city" => "London", "units" => "celsius"}
}
```

### ToolResult

```elixir
defmodule Omni.Content.ToolResult do
  defstruct [:tool_use_id, :name, :content, is_error: false]
end
```

Represents the result of a tool use, sent back to the model in a user message. The `tool_use_id` links this result to the corresponding `ToolUse` block; `name` is the tool's name, which some wire formats (Gemini) need on the result.

`content` is always a list of content blocks (text, or text with images). `ToolResult.new/1` accepts a string for the common case and wraps it in a `Text` block.

The `is_error` boolean flag tells the model the tool use failed. The error details are the content itself -- there's no separate `details` field because the model doesn't need structured exception data, just a message describing what went wrong.

```elixir
# Simple string result
ToolResult.new(
  tool_use_id: "call_abc123",
  name: "get_weather",
  content: "15C, cloudy with a chance of rain"
)

# Rich result with image
%ToolResult{
  tool_use_id: "call_abc123",
  content: [
    %Content.Text{text: "Here's the forecast chart:"},
    %Content.Attachment{source: {:base64, chart_data}, media_type: "image/png"}
  ]
}

# Error result
ToolResult.new(
  tool_use_id: "call_abc123",
  name: "get_weather",
  content: "Connection timeout: could not reach weather API",
  is_error: true
)
```

### Summary

| Block | Fields | Appears in |
|-------|--------|------------|
| `Content.Text` | text, signature | User and assistant messages |
| `Content.Thinking` | text, signature, redacted_data, id | Assistant messages |
| `Content.Attachment` | source, media_type, meta | User messages (and tool results) |
| `Content.ToolUse` | id, name, input, signature | Assistant messages |
| `Content.ToolResult` | tool_use_id, name, content, is_error | User messages |

---

## Streaming

### Overview

The streaming design has three layers, each with a clear responsibility:

1. **Stream parser** (shared) -- decodes raw bytes into individual JSON event maps. `Request.stream/3` selects the parser based on the response `content-type` header: `NDJSON` for newline-delimited JSON (Ollama), `SSE` for everything else.
2. **Dialect** (per-API-family) -- transforms a JSON event map into a normalised delta tuple
3. **StreamingResponse** (shared) -- accumulates deltas into a partial response, emits rich consumer events

The event pipeline is composed as a lazy stream using Req's `into: :self` async mode and Elixir's `Stream` functions:

```
Req async response (into: :self)
    │  → raw binary chunks arrive as messages
    ▼
SSE.stream/1 or NDJSON.stream/1 (selected by content-type)
    │  → decoded JSON map (one at a time, buffering across chunks)
    ▼
dialect.handle_event/2 (parse to delta tuples; receives the model)
    │  → [{delta_type, delta_map}] list
    ▼
StreamingResponse Enumerable (wraps the delta stream)
    │  → accumulates partial Response
    │  → yields {event_type, event_map, partial_response}
    ▼
Consumer receives rich events
```

**No spawned process.** With Req's `into: :self`, the HTTP client (Finch) manages the connection in its own process pool and delivers body chunks as messages to the calling process. The `stream_text` orchestration composes a lazy `Stream` pipeline that receives these chunks, parses them (SSE or NDJSON depending on content-type), and produces delta tuples. `StreamingResponse` wraps this lazy stream, adding accumulation logic. Everything runs in the caller's process -- no spawned process, no monitors, no message passing between Omni-owned processes.

StreamingResponse itself is a generic mechanism -- it wraps a pre-built lazy stream of delta tuples and accumulates them, with no knowledge of providers, dialects, or HTTP.

### StreamingResponse

`Omni.StreamingResponse` is a struct that implements the `Enumerable` protocol. It is returned by `stream_text` and serves as both the iterable and the cancellation handle.

```elixir
defmodule Omni.StreamingResponse do
  defstruct [:stream, :cancel]
end

defimpl Enumerable, for: Omni.StreamingResponse do
  def reduce(sr, cmd, fun) do
    Enumerable.reduce(sr.stream, cmd, fun)
  end
end
```

The struct holds two fields:

- `stream` -- the pre-built consumer event pipeline (built at construction time via `Stream.transform/5`)
- `cancel` -- a zero-arity function to cancel the underlying HTTP request (or nil)

Model, raw HTTP data, and all accumulation state are baked into the `Stream.transform/5` closure at construction time -- they are not stored on the struct. This keeps the struct minimal and provider/HTTP-agnostic.

The constructor takes raw delta events and builds the full pipeline:

```elixir
StreamingResponse.new(deltas,
  model: model,
  cancel: fn -> Req.cancel_async_response(resp) end,
  raw: if(opts[:raw], do: {req, resp})
)
```

Consumers interact with it through four key functions:

- `on/3` -- register a side-effect handler for an event type (returns a new `StreamingResponse` with the handler in the pipeline)
- `complete/1` -- consume the stream to the final `%Response{}`
- `text_stream/1` -- return a stream of text delta binaries (when you only need text, no `Response`)
- `cancel/1` -- cancel the underlying HTTP request

`on/3` is pipeline-composable: it wraps the stream in a `Stream.each/2` that fires the callback for matching events. Nothing executes until a consumer (typically `complete/1`) drives the pipeline. Callbacks accept arity-1 (event map only) or arity-2 (event map + partial response).

```elixir
{:ok, stream} = Omni.stream_text(model, context)

# Side effects during streaming + final response (most common pattern)
{:ok, response} =
  stream
  |> Omni.StreamingResponse.on(:text_delta, fn %{delta: d} -> IO.write(d) end)
  |> Omni.StreamingResponse.on(:thinking_delta, fn %{delta: d} -> IO.write(d) end)
  |> Omni.StreamingResponse.complete()

# LiveView: send chunks to the LiveView process
{:ok, response} =
  stream
  |> Omni.StreamingResponse.on(:text_delta, fn %{delta: d}, _partial ->
    send(self(), {:llm_chunk, d})
  end)
  |> Omni.StreamingResponse.complete()

# Just get the text chunks (no Response needed)
text = stream |> Omni.StreamingResponse.text_stream() |> Enum.join()

# Just get the final response (no streaming side effects)
{:ok, response} = Omni.StreamingResponse.complete(stream)

# Cancel a stream
Omni.StreamingResponse.cancel(stream)
```

**Finalization:** `Stream.transform/5`'s `last_fun` handles stream finalization -- emitting block `_end` events and the `:done` event. This replaces a synthetic sentinel approach. On error, `last_fun` emits block `_end` events (so consumers get finalized partial content) but no `:done` -- the `:error` event is the terminal event.

**Why no spawned process?** Req's `into: :self` mode handles async delivery -- the HTTP client (Finch) manages connections in its own process pool and sends body chunks as messages to the calling process. `StreamingResponse` wraps a lazy stream that receives and transforms these messages. Cancellation is via an opaque function passed at construction time. No Omni-owned process is needed, eliminating the complexity of process lifecycle management, bidirectional monitors, and failure propagation.

### Stream parsers

Two shared parsers sit between Req and the dialect, selected by response content-type:

- **`Omni.Parsers.SSE`** -- handles Server-Sent Events framing: buffering incomplete events across TCP chunks, splitting multi-event payloads, stripping `data:` prefixes, detecting `[DONE]` sentinels, filtering pings/keepalives, and decoding JSON. Used by most providers.
- **`Omni.Parsers.NDJSON`** -- handles newline-delimited JSON: splits on `\n`, decodes each line as JSON, skips empty/invalid lines, flushes buffer at stream end. Used by Ollama's native API.

Both parsers expose the same `stream/1` interface — accepting an enumerable of binary chunks and returning a stream of decoded JSON maps. `Request.stream/3` selects NDJSON when the response `content-type` contains `"ndjson"` (local Ollama sends `application/x-ndjson`) or starts with `application/json` (ollama.com labels its NDJSON stream that way); all other responses default to SSE.

### Dialect event parsing

Each dialect's `handle_event/2` (see [Dialect callback details](#dialect-callback-details)) receives one decoded event map and the model, and returns a list of delta tuples -- `[]` to drop the event, several when one event bundles data that maps to separate deltas. It is stateless; accumulation is StreamingResponse's job.

### Internal delta format

Dialect deltas are the contract between dialects and StreamingResponse. There are four types (documented for dialect authors in the `Omni.Dialect` moduledoc):

```elixir
# Message-level metadata, folded into the accumulating response (no consumer event)
{:message, %{model: "claude-sonnet-5-5"}}
{:message, %{stop_reason: :stop, usage: %{...}}}
{:message, %{private: %{reasoning_details: [...]}}}   # merged into Message.private

# A content block starts: :type is :text, :thinking or :tool_use
{:block_start, %{type: :text, index: 0}}
{:block_start, %{type: :tool_use, index: 1, id: "call_1", name: "weather"}}
{:block_start, %{type: :thinking, index: 0, redacted_data: "..."}}

# An incremental update; thinking deltas may carry :signature
{:block_delta, %{type: :text, index: 0, delta: "Hello"}}
{:block_delta, %{type: :tool_use, index: 1, delta: "{\"city\":"}}

# A streaming error: a bare reason, not a map
{:error, "overloaded_error"}
```

Dialects never emit block-end or done events. StreamingResponse derives them: a block ends when the next starts or the stream finishes, and `:done` follows only if a stop reason arrived.

Tool use deltas carry string fragments of the JSON-encoded input. StreamingResponse joins and parses the complete JSON into a map. Dialects whose APIs send arguments whole (Gemini, Ollama) emit the input in one delta.

### Consumer-facing event format

The `StreamingResponse` enumerable yields three-element tuples: `{event_type, event_map, partial_response}`. The content type is encoded in the event type atom, so every event is self-describing -- you can pattern match a single event without tracking state from previous events:

```elixir
{:text_start, %{index: 0}, %Response{...}}
{:text_delta, %{index: 0, delta: "Hello"}, %Response{...}}
{:text_end, %{index: 0, content: %Text{}}, %Response{...}}
{:thinking_delta, %{index: 1, delta: "Let me think..."}, %Response{...}}
{:tool_use_start, %{index: 2, id: "call_123", name: "weather"}, %Response{...}}
{:tool_use_delta, %{index: 2, delta: "{\"city\":"}, %Response{...}}
{:tool_use_end, %{index: 2, content: %ToolUse{}}, %Response{...}}
{:tool_result, %ToolResult{}, %Response{...}}   # between loop steps; third element is that step's completed response
{:done, %{stop_reason: :stop}, %Response{...}}
{:error, reason, %Response{...}}
```

The `_end` events carry the completed content block struct. Consumers who don't want to process deltas can listen only for `_end` events and get finished blocks.

Every stream ends with exactly one terminal event. `:done` is emitted only when the provider sent a stop reason; a stream that ends without one emits `{:error, :incomplete_stream}`. A mid-stream provider error emits `{:error, {:stream_error, reason}}`. `:cancelled` is in the stop-reason type for callers that cancel a stream and record the outcome (such as `omni_agent`); Omni itself never sets it.

**Partial response on every event.** The partial `%Response{}` is accumulated by the `StreamingResponse` as events arrive. Elixir's structural sharing means this is memory-efficient -- each update creates a new struct shell pointing to mostly the same underlying data. The `on/3` API makes it easy to combine side effects with response collection:

```elixir
# Stream text to console + get final response
{:ok, response} =
  stream
  |> StreamingResponse.on(:text_delta, fn %{delta: delta} -> IO.write(delta) end)
  |> StreamingResponse.complete()

# Build a UI showing the full response state as it streams
{:ok, response} =
  stream
  |> StreamingResponse.on(:text_delta, fn _event, partial -> update_ui(partial) end)
  |> StreamingResponse.complete()

# React to tool uses + stream text simultaneously
{:ok, response} =
  stream
  |> StreamingResponse.on(:text_delta, fn %{delta: d} -> IO.write(d) end)
  |> StreamingResponse.on(:tool_use_end, fn %{content: tool_use} -> log_tool(tool_use) end)
  |> StreamingResponse.complete()
```

Direct `Enum.each/2` iteration is still available for advanced cases where manual control over every event is needed.

### Error handling

Errors are categorised into two surfaces:

**Pre-stream errors** surface as `{:error, reason}` from `stream_text/3`. These include an unknown provider or model (`{:error, {:unknown_provider, id}}`, `{:error, {:unknown_model, ...}}`), validation failures, attachments the model can't take (`{:error, {:unsupported_media_type, type}}`), authentication errors (`{:error, :no_api_key}`), and non-200 status codes (`{:error, {:http_error, status, body}}`). The stream never starts.

**Mid-stream errors** (provider errors partway through a streaming response) are wrapped as `{:error, {:stream_error, message}, partial_response}` events through the enumeration, after which the stream terminates. The `{:stream_error, message}` tuple distinguishes mid-stream errors from pre-stream errors at the call site. Dialects emit raw `{:error, message}` deltas; `StreamingResponse` wraps these into `{:stream_error, message}` during processing. A stream that ends with no stop reason is `{:error, :incomplete_stream}`.

`StreamingResponse.complete/1` returns `{:ok, %Response{}} | {:error, reason}`. If a mid-stream error occurs, `complete/1` returns `{:error, {:stream_error, message}}` -- the partial response is discarded. Consumers who care about partial data under failure should consume the stream manually, where they receive valid chunks followed by the error event.

```elixir
# complete/1 gives clean ok/error semantics
with {:ok, stream} <- Omni.stream_text(model, context),
     {:ok, response} <- Omni.StreamingResponse.complete(stream) do
  response
end

# Manual consumption gives access to partial data on error
Enum.each(stream, fn
  {:error, {:stream_error, message}, _partial} -> handle_error(message)
  {:text_delta, %{delta: delta}, _} -> IO.write(delta)
  _ -> :ok
end)
```

---

## Decisions

A decision sends one shared input (the **state**) and a set of independent, typed questions, and gets back calibrated probabilities instead of prose. No streaming, tools, multi-turn or thinking. Two wire formats cover every known host: TypeSafe's **System One** (the de facto open standard: TypeSafe, OpenRouter, OpenCode Zen, Ollama, NearAI, and Alibaba, Venice, Cloudflare, Liquid and others not built in) and **OpenAI Decisions** (`gpt-6-luna` only). Hosts differ in paths, option caps, confidence formulas and image encodings; none of that needs a third dialect.

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
```

### Data

- **`%Omni.Decision{state, questions, answers, usage, model, raw}` is both request and result.** Built from state and questions (`Decision.new/1` also takes the `{state, questions}` shorthand), it passes through the dialect and `modify_body/4` with `answers` and `usage` nil, and comes back filled. One struct means the hook, the dialect and the caller see one shape, and the result keeps the questions beside the answers.
- **State** is a non-empty string, map or list: anything JSON-encodable. Content blocks, `%Context{}` and images are deferred, with System One's `box` question type.
- **Questions** are a keyword list: the atom key names the question, and the order is OpenAI's answer order. Structs follow the Content convention (match on struct, no type field): `Question.Predicate{instructions, criteria}`, `Question.Choice{instructions, choices}`, `Question.Score{instructions, levels}`, built with `Question.predicate/2`, `choice/2`, `score/2` (delegated from `Omni`). Constructors normalise choices and levels (a bare list, `key: description` pairs, or a mix) to `{key, description | nil}`; keys are atoms or strings and come back as given. Instructions are a string, map or list. The yes/no primitive is `predicate` (OpenAI's name); System One's `noul` is an encoding detail.
- **Answers** are a keyword list aligned with the questions: `Answer.Predicate{probability}`, `Answer.Choice{choice, probabilities, confidence}`, `Answer.Score{score, probabilities, confidence}`, `Answer.Refusal{}` (OpenAI only). `probabilities` is `[{key, float}]` with the caller's keys in the caller's order. Score levels start at 0 on both APIs, so `score` (the probability-weighted level) is one scale everywhere.
- **Probabilities pass through as sent.** TypeSafe rounds to two decimals, Ollama sends full floats; Omni rounds neither (rounding loses ranking at the tails and stops probabilities summing to 1), and only makes JSON integers (`1`, `0`) floats.
- **Confidence is the provider's number**, `nil` where the API gives none. Formulas differ (TypeSafe `(p_max − 1/n) / (1 − 1/n)`; Ollama and others entropy `1 − H/ln N`; OpenAI unspecified), so probabilities are the portable contract.

### Validation and errors

- **One Peri pass at the boundary** (`Decision.validate/1`, in `Request.build/3`): non-empty state; a non-empty keyword list of question structs with unique names; non-empty instructions; at least two choices or levels. That is the floor every host accepts. Host caps (26 choices on some hosts, 255 on most; 16 questions on Alibaba; required `instructions` on some) are left to the provider's HTTP error.
- **Strict answers.** A missing answer, one for a question not asked, or one of the wrong shape is `{:error, {:invalid_answer, name}}`; a body with no answers `{:error, {:invalid_response, body}}`. Extra top-level fields are ignored (OpenRouter's `id`, `provider`, `usage.cost`; Alibaba's `request_id`). The matching rule is shared by both dialects in `Omni.Dialect.Decision.Answers` (internal).

### Encoding

| | System One | OpenAI Decisions |
|---|---|---|
| Path | `/systemone` | `/decisions` |
| State | `state`, as given | a string as `input`; a map or list as one `input_json` part of a user message |
| Questions | a map keyed by name: `{type, instructions, criteria}` | an array in order, each with `name` |
| Predicate | `noul`; criteria as `{"true": ..., "false": ...}` | `predicate`; criteria dropped (no field) |
| Choice | `criteria: {key: description \| null}` (null: judged by the key) | `choices: [{value, description?}]`, values always strings |
| Score | `criteria`: a list of descriptions, the key standing in for a missing one | `levels: [{label, description?}]` |
| Instructions | as given | a map or list JSON-encoded (instruction parts take text only) |
| Answers | a map by name; choice probabilities keyed by option, score by level index; `legend` dropped | an array; `{type: "refusal"}` is `Answer.Refusal` |
| Usage | `input_tokens`, `output_tokens` (Alibaba: input only) | `input_tokens` less `cached_tokens`, which become `cache_read_tokens` |
| Options | none | `safety_identifier`, `prompt_cache_key` |

Choice and level keys must differ as strings, since both formats key by string. Every catalogued decision model is priced per input token (output at 0), some with cache reads, so `%Usage{}` fits unchanged. `gpt-6-luna` carries its chat output price, but OpenAI's decision responses report 0 output tokens.

### Hosts

| Provider | Dialect | Endpoint URL | Models |
|---|---|---|---|
| `:typesafe` | System One | `https://api.typesafe.ai/v1` | listed by the module (no models.dev entry). System One's home API |
| `:openai` | OpenAI Decisions | `https://api.openai.com/v1` | `gpt-6-luna`, stamped by the module |
| `:openrouter` | System One | `https://openrouter.ai/api/v1` | catalog, including `openai/gpt-6-luna-decisions` (System One in front of OpenAI). The URL is set in the module: llm_db places these models at the origin, for OpenRouter's alpha route `/api/alpha/decisions` (same wire, "shape may change") |
| `:opencode` | System One | `https://opencode.ai/inference/systemone/v1` (catalog) | `jev-1.13`, `jev-1.13-free` |
| `:ollama` | System One | `http://localhost:11434/v1` | config, naming `dialects: %{decision: Omni.Dialects.SystemOne}` |
| `:nearai` | System One | `https://cloud-api.near.ai/v1` (catalog) | catalog; endpoint undocumented, unverified (no key) |

Not adopted yet: images and `box` (each host encodes images differently: TypeSafe `assets` behind a header, Ollama and Venice `images`, OpenRouter `image_url` parts, OpenAI `input_image`), confidence normalised from probabilities, warnings for silently dropped fields (predicate criteria on OpenAI). Hosts awaiting catalog data are in the roadmap.

---

## Request Flow

### The stream_text pipeline

`Omni.stream_text/3` resolves a `{provider_id, model_id}` tuple to a `%Model{}`, coerces the context with `Context.new/1`, and hands both to `Omni.Loop.stream/3`. The loop owns multi-step behaviour; `Omni.Request` owns one request. The code below is illustrative, not the exact implementation:

```elixir
# In Omni.Request:
def build(%Model{provider: provider} = model, context, opts) do
  with {:ok, dialect} <- Model.dialect(model, :text),          # {:unsupported_capability, :text}
       {:ok, endpoint} <- Provider.endpoint(provider, dialect), # {:no_endpoint, dialect}
       {:ok, opts} <- validate(model, :text, opts),
       :ok <- validate_context(model, context),
       {:ok, url} <- url(endpoint, dialect, model, opts) do     # host: swap; {:no_base_url, dialect}

    body =
      model
      |> dialect.handle_body(context, opts)
      |> module_modify_body(provider, model, context, opts)   # provider.module.modify_body/4, if defined

    req = Req.new(method: :post, url: url, json: body, into: :self,
                  receive_timeout: opts.timeout, headers: opts.headers, plug: opts[:plug])

    with {:ok, req} <- authenticate(req, auth_scheme(provider, dialect), opts.api_key) do
      module_modify_request(req, provider, opts)               # provider.module.modify_request/3, if defined
    end
  end
end

def stream(req, model, opts) do
  with {:ok, resp} <- Req.request(req), :ok <- check_status(resp) do
    deltas =
      resp.body
      |> select_parser(resp).stream()                          # SSE or NDJSON
      |> Stream.flat_map(&model.dialects.text.handle_event(&1, model))

    {:ok, StreamingResponse.new(deltas,
      model: model,
      cancel: fn -> Req.cancel_async_response(resp) end,
      raw: if(opts[:raw], do: {req, resp}))}
  end
end
```

The key architectural points:

- **Everything comes from the model.** The dialect is `model.dialects.text`; the endpoint (URL and compat), key, auth, headers and module are on `model.provider`. Nothing is looked up at request time.
- **The URL is one join.** `endpoint.base_url`, its origin swapped by a call-site `host:`, plus `dialect.handle_path/2`. An endpoint with no URL, or one still holding a placeholder, is `{:error, {:no_base_url, dialect}}` before any HTTP.
- **`validate/3` is a two-tier merge plus one strict pass.** The provider's `api_key` and `headers` sit under the call-site opts (headers merge by key), and the merged map is validated against the capability's schema plus `dialect.option_schema/0`. Every callback receives the one validated map, config and inference options together.
- **`validate_context/2`** rejects attachments whose media type the model's `input_modalities` don't cover, before anything is sent.
- **Auth is data.** `auth_scheme/2` maps `:dialect` (and an unset value, for hand-built structs) to `dialect.auth/0`; `:none` sends nothing; `:bearer` and `{:header, name}` resolve the key with `Provider.resolve_auth/1`, returning `{:error, :no_api_key}` when there is none. `modify_request/3` runs after, so it can overwrite anything.
- **`:timeout` with a generous default.** Defaults to 300,000ms (5 minutes), mapped to Req's `receive_timeout`: the longest wait for each chunk, not for the whole response, so a stream that keeps arriving is never cut off. LLM APIs routinely exceed Req's default 15s before the first token, especially thinking models.
- **Status check catches HTTP errors early.** Non-200 responses are read and turned into `{:error, {:http_error, status, body}}` before any streaming begins.
- **The event stream is lazy composition.** `resp.body` is a `Req.Response.Async` enumerable of raw chunks; the parser turns them into JSON maps and the dialect into deltas. Nothing executes until the consumer drives the stream.
- **`validate/3`, `parse_event/2` and `validate_context/2` are `@doc false` public functions**, exposed for unit tests. The module's API is `build/3`, `stream/3` and `send/4`.
- **StreamingResponse is generic.** It receives delta tuples and builds the consumer pipeline via `Stream.transform/5`; it has no knowledge of providers, dialects, or HTTP.

### The loop

`Omni.Loop` turns one or more requests into a single `StreamingResponse`. It pops `:raw`, `:max_steps` (default `:infinity`) and `:tool_timeout` (default 30s), then streams the first step. Each step's events pass through to the consumer; when a step's `:done` arrives, a recursive `Stream.flat_map` either emits the terminal event or returns the next step's lazy stream:

- **Tool auto-execution.** If the response has tool use blocks and every named tool has a handler, `Tool.Runner` executes them in parallel, emits a `:tool_result` event per result, pushes the assistant message and a user message of `ToolResult` blocks onto the context, and streams the next step. A tool with no handler (schema only) ends the loop so the caller can handle it. A hallucinated tool name gets an error result sent back, and the loop continues. `:max_steps` caps the rounds; `1` disables looping.
- **Structured output.** With `:output` set, the final text is JSON-decoded and validated against the schema into `response.output`. On failure the loop sends the error back and retries, up to 3 times. A `:length` stop is not retried.

The final `%Response{}` carries every message from every step in `messages`, cumulative `usage`, and one `raw` tuple per step.

### The decide pipeline

`Omni.decide/3` resolves the model, coerces the decision with `Decision.new/1`, pops `:raw`, and calls `Request.build/3` then `Request.send/4`. No loop.

- **`build/3` matches on the struct**: a `%Decision{}` takes `Model.dialect(model, :decision)` and its endpoint, validates options against the config schema plus the dialect's, runs `Decision.validate/1`, and builds the body and URL the same way as text (same `modify_body/4`, auth and `modify_request/3`), without `into: :self`.
- **`send/4`** runs the request, `check_status`, decodes the JSON body, calls `dialect.handle_response/3`, and prices the usage with `Usage.price/2`, the cost computation `StreamingResponse` uses too. The decision comes back with `answers`, `usage`, `model`, and `raw` (`{req, resp}` with `raw: true`).

### High-level flow diagram

```
Omni.stream_text(model, context, opts)
├── 1. Resolve model ({provider_id, model_id} → %Model{}, via the store)
├── 2. Coerce context (Context.new/1)
└── 3. Loop.stream(model, context, opts)
      ├── Pop :raw, :max_steps, :tool_timeout
      ├── Request.build(model, context, opts)
      │     ├── endpoint = provider.dialects[model.dialects.text]
      │     ├── validate: provider api_key/headers <- call-site opts; one strict Peri pass
      │     ├── validate_context: attachment media types vs model modalities
      │     ├── url  = endpoint.base_url (origin ← host:) <> dialect.handle_path(model, opts)
      │     ├── body = dialect.handle_body(model, context, opts)   (reads endpoint compat)
      │     │          |> module.modify_body/4                     (optional)
      │     ├── Req.new(url, json: body, into: :self, receive_timeout: timeout, headers, plug)
      │     ├── authenticate per provider.auth (:dialect → dialect.auth/0)
      │     └── module.modify_request/3                            (optional)
      ├── Request.stream(req, model, raw: raw)
      │     ├── Req.request → resp (body is Req.Response.Async)
      │     ├── check_status → :ok | {:error, {:http_error, ...}}
      │     ├── parser (SSE | NDJSON by content-type) |> dialect.handle_event(event, model)
      │     └── StreamingResponse.new(deltas, model:, cancel:, raw:)
      └── On :done: run tools / validate output → next step, or terminal event
Return {:ok, StreamingResponse.t()} | {:error, term()}
```

---

## Verification and testing

### Two jobs

- **Does Omni handle real wire bytes?** Offline, in CI, from recorded fixtures: the integration tests.
- **Does this provider's current lineup work?** Live calls only: `mix omni.verify`, and the sweep script over it.

A fixture can't say a provider works today; verify can't guard against regressions in CI. Each tool does one job. All live calls (verify, the sweep, capture scripts) are made by the maintainer, never by an agent or CI.

### Verify

`mix omni.verify <provider> <model>` ships in the package, so users can check a catalog or custom provider, or a new model on a built-in, against their own config. The task is a thin wrapper over `Omni.Verify` (internal), whose `run/3` returns results as data (`%{scenario, status, time_ms, summary, error}`); the sweep calls the same function. A catalog provider that isn't loaded is loaded for the run. Text output is capped at 8192 tokens so a runaway generation fails with `:length`.

Scenarios are a fixed set, toggled by flags. The defaults follow the model's capabilities, added together: text brings `text`, `thinking`, `tool_use`, `structured_output`; decision brings `decision` and `decision_json`; `gpt-6-luna` runs all six. Nothing else is chosen from model data. Requests live in `Omni.Verify.Scenarios`, which capture scripts and tests share.

| Scenario | Default on | Request | Passes when |
|---|---|---|---|
| `text` | text | simple prompt, `thinking: false` | stop `:stop`, non-empty text |
| `thinking` | text | a question hard enough to reason over, `thinking: :low` | a thinking block (text, signature or redacted data) and text |
| `tool_use` | text | weather tool, no handler | a `get_weather` `ToolUse` for London, stop `:tool_use` |
| `structured_output` | text | object schema via `:output` | `resp.output` matches the schema |
| `no_thinking` | no | the thinking question, `thinking: false` | no thinking blocks. Only meaningful where model data says thinking can switch off (a toggle or a `"none"` effort); elsewhere Omni sends nothing |
| `image` | no | `priv/verify/logo.png` | answer names the brand |
| `pdf` | no | `priv/verify/whitepaper.pdf` | answer names the author |
| `kitchen_sink` | no | thinking on, two tools with handlers, a prompt needing both; then a follow-up turn over the whole history | ≥1 tool round and text on both turns. Covers thinking replay (signatures, `Message.private`) across tool rounds |
| `cache_usage` | no | long system prompt with `cache: :short`; turn 2 on top of turn 1 | turn 2 reports cache-read tokens. Exercises breakpoint placement: the prefix must re-encode byte-identically |
| `decision` | decision | a string state; a predicate with both criteria, a choice with one undescribed option, a score with bare level keys | every answer well formed (floats from 0 to 1, keyed by the question's options in order, no refusal, input tokens counted), the predicate over 0.5 and the obvious choice. The score is checked for shape only |
| `decision_json` | decision | a map state and map instructions (OpenAI's `input_json` and JSON-encoded instruction paths) | the same rule. Shows the host accepts the JSON form |

Decision questions are unambiguous on purpose: a small model can be strict on fuzzy ones (a 2B model rejected a one-letter name typo outright). Baselines assert the same rule (`Scenarios.check_decision/2`).

Rules:

- **Pass or fail only.** No skip, no warn, no retries (Omni doesn't retry; Req's default retry covers only GET and HEAD). A model failing a scenario it can't do is a correct failure; the sweep matrix doesn't ask it. Flaky results are investigated: tighten the prompt, or drop the scenario for that model.
- **Thinking effort levels aren't verified** — there's no reliable way to measure the level applied. `thinking` is lenient on purpose: whether a model emits reasoning text varies.
- **Output is generic.** Each result line has a short reason (`HTTP 429`, `stream error`, `no thinking`), never provider text; errors print in full after the run. Request bodies aren't shown.
- **Flags:** `--only a,b` (exactly these), `--add` / `--skip` (adjust the defaults), `--delay ms` (pause between scenarios).

### Sweep

`scripts/verify/sweep.exs` holds a matrix as data: `{provider, model, selection}`, the model a catalog id or `Model.new/1` attributes where the catalog lacks it (local Ollama, Z.ai vision). It runs `Omni.Verify.run/3` on each entry in turn and skips providers without an API key. Targets are `provider` or `provider/model`; a model outside the matrix runs the defaults; `--only` replaces every target's selection.

Models are chosen provider by provider: cheap to mid-range, a premium model from Anthropic and OpenAI, more than two for gateways, and the decision models of each built-in that has them (plus OpenRouter's `openai/gpt-6-luna-decisions`). The matrix tracks today's common models and shifts with lineups. Google has no `cache_usage`: Gemini's implicit cache never reported a hit, and there's no request-side cache control to verify.

Results accumulate by day in `scripts/verify/results/YYYY-MM-DD.json` (`{status, result, time_ms}` per model and scenario, `result` being the short line). A run overwrites the cells it ran and keeps the rest, then regenerates the `.md` beside it. No provider errors are saved, so results are committed. Nothing is pruned.

Sequential throughout: runs are infrequent.

### Capture

Each fixture directory has a `capture.exs`, run with `MIX_ENV=test mix run test/support/fixtures/<dir>/capture.exs`. It calls `Omni.Test.Capture.record/4` once per fixture, each call naming its file:

- **Existing files are skipped.** Re-recording means deleting the file, so new cases can be added without paying for the rest.
- **One request per fixture**, built with `Request.build/3` (the request the loop sends on each step) and its raw bytes written: `.sse` or `.ndjson` for text, `.json` for a `%Decision{}` (replayed through `decide/3`). Not `generate_text` with `raw: true`: the async body is consumed while parsing, and the loop's structured-output retries would hide extra responses. Multi-step cases chain `record` calls by hand with `with`, so a failure skips its follow-ups and the script carries on.
- **Then always replayed** through `generate_text` with a plug serving the file, so first and later runs return the same thing, and a turn 2 is built from turn 1 exactly as recorded.
- `:pause` waits before a live request, for tight rate limits (Moonshot).
- Response bytes only; no request fixtures.

Baseline requests come from `Omni.Verify.Scenarios` (via `Omni.Test.Baseline.request/1`), so a baseline fixture is a recording of what verify checks. Requests for other cases live in `Omni.Test.Cases`, which also names each dialect's reference model.

### Integration test tiers

Every fixture lives in the lowest tier where it is the only set of real bytes exercising some parsing path or provider variation. Tests only load fixtures from their own directory.

| Tier | Protects | Tests | Fixtures |
|---|---|---|---|
| Omni | `StreamingResponse`, `Loop` | `loop_test`, `error_test`, `structured_output_test` (and unit tests of the same modules) | `anthropic/`, plus `synthetic/` |
| Dialect | a parser path any provider on the dialect takes | `dialects/<dialect>_test.exs` | `dialects/<dialect>/`, from the home API |
| Provider | bytes where a provider differs from its dialect's reference | `<provider>_test.exs` | `<provider id>/` |

- **Reference providers** are each dialect's home API, matching what "no compat flags" means: Anthropic (`claude-haiku-5-5`), OpenAI Responses and Decisions (`gpt-6-luna`), Google (`gemini-3.8-flash`), local Ollama, and OpenAI's own `/chat/completions` for Completions (`gpt-6-luna` re-stamped to the Completions dialect, since no built-in speaks it).
- **Dialect cases** cover what every provider on the dialect shares: cache read/write (`cache_1`, `cache_2`), length stops mid tool call (`tool_length`, `length`), parallel tool calls and reasoning replay (`tools_1`, `tools_2`), Anthropic redacted thinking, and synthetic error events.
- **Provider files** have a `baseline` block — text, thinking, tool use (via `Omni.Test.Baseline`), the request target (host, path, auth headers) and request shape, including where earlier reasoning goes (`replay_thinking/3`) — then `cases` and `synthetic` blocks only for genuine quirks. Providers with decision models baseline `decision` and `decision_json` with their target: TypeSafe `jev-1.14.0`, OpenAI `gpt-6-luna`, OpenRouter `typesafe/jev-1.14`, OpenCode `jev-1.13-free`, Ollama `pplx-decider-flash:4b-nvfp4`. The OpenAI Decisions dialect tier holds only a cache read (two turns over a 7k-token state). No refusal fixture (OpenAI documents no trigger; a unit test covers it) and no decision error fixtures (HTTP errors share `check_status`). Most have neither. OpenCode runs a dialect and target test per dialect from its `*_text` fixtures.
- **Request shape is asserted, not snapshotted:** capture the outgoing body via the plug and assert the fields the provider's compat flags control. Dialect unit tests cover each flag in isolation.
- **No structured output fixtures.** Parsing is plain text on every dialect; whether a provider obeys the schema is verify's job. Its request fields are asserted in request shape tests.
- **Baseline assertions survive re-recording:** stop reason, tool input mentions London, usage present; thinking is lenient (text, signature or encrypted reasoning).
- **Synthetics live with their tier:** dialect-level in the dialect directory, provider-level with the provider (Venice's packed chunks, OpenRouter's error), Omni-level in `synthetic/`.
- **Tests look models up from the catalog.** When a snapshot refresh drops a model, the test breaks and the fixture is re-recorded on a current model. Keeping tests on current models is part of the job.

Recording notes: at `thinking: :low`, Haiku 5.5 and gpt-6-luna answered the tool question without reasoning, so their `tools_1`/`tools_2` cases use `Cases.request(:thinking_tools)` (`thinking: :high` and a system prompt asking to plan first). OpenAI's `/chat/completions` rejects tools with a reasoning effort other than `"none"` on gpt-6-luna, so the Completions `tools_1` reference has thinking off. Groq and Ollama Cloud fixtures come from the models their free tiers allow; NearAI's are legacy recordings (no key), with a `capture.exs` ready to replace them.

---

## Module Structure

```
lib/omni.ex                    # Top-level API: generate_text, stream_text, decide, get_model,
                               #   list_models, put_model, get_provider, constructors
lib/omni/
├── application.ex             # Boots Omni.Provider.Loader at startup
├── model.ex                   # Model struct, new/1, get/list/put, to_ref/1
├── context.ex                 # Context struct, new/1, push/2
├── message.ex                 # Message struct (role, content blocks, timestamp, private)
├── response.ex                # Response struct (message envelope with metadata)
├── streaming_response.ex      # StreamingResponse struct, Enumerable impl,
│                              #   on/3, text_stream/1, complete/1, cancel/1
├── usage.ex                   # Usage struct, price/2, add/2, sum/1
├── decision.ex                # Decision struct (request and result), new/1, validate/1
├── question.ex                # predicate/2, choice/2, score/2
├── question/                  # Predicate, Choice, Score structs
├── answer.ex                  # Answer.t() union and moduledoc
├── answer/                    # Predicate, Choice, Score, Refusal structs
├── codec.ex                   # Lossless struct ↔ JSON-safe map serialisation
├── util.ex                    # Shared helpers (maybe_put, maybe_merge, put_path)
├── tool.ex                    # Tool struct, behaviour, use macro, execute/2
├── tool/
│   └── runner.ex              # Parallel tool execution (ToolUse → ToolResult)
├── schema.ex                  # JSON Schema builder + Peri-backed validator;
│                              #   default Omni.Schema.Adapter implementation
├── schema/
│   └── adapter.ex             # Behaviour for pluggable schema validators
├── content/
│   ├── text.ex                # Text content block
│   ├── thinking.ex            # Thinking/reasoning content block
│   ├── attachment.ex          # Generic attachment (images, PDFs)
│   ├── tool_use.ex            # Tool use content block
│   └── tool_result.ex         # Tool result content block
├── parsers/
│   ├── sse.ex                 # SSE stream parser (framing, decoding, buffering)
│   └── ndjson.ex              # NDJSON stream parser (Ollama)
├── request.ex                 # Request orchestration: build/3, stream/3, send/4,
│                              #   validate/3, parse_event/2, validate_context/2
├── loop.ex                    # Recursive stream loop (tools, structured output retries)
├── verify.ex                  # Live verification runner (internal): select/1, run/3
├── verify/
│   └── scenarios.ex           # Scenario requests, shared with capture scripts and tests
├── provider.ex                # Provider struct, module behaviour, get/1, load/1,
│                              #   builtins/0, resolve_auth/1
├── provider/
│   ├── builtins.ex            # Built-in ids → Omni.Providers.* modules
│   ├── endpoint.ex            # Endpoint struct (base_url, compat), host: helpers
│   └── loader.ex              # Assembly, merging, validation, store, boot config checks
├── providers/
│   ├── alibaba.ex             # One module per built-in: config/0 is the built-in
│   ├── anthropic.ex           #   overlay; moduledoc is the provider reference
│   └── ...
├── source.ex                  # Source behaviour, build_model/1, pass-scoped cache
│                              #   (with_cache/1, memo/2)
├── sources/
│   ├── models_dev.ex          # Default source: bundled models.dev snapshot + live mode
│   └── llmdb.ex               # Optional source backed by the llm_db package
├── dialect.ex                 # Base behaviour (auth/0, compat_schema/0), `use`, registry
│                              #   (get/1), compat/2, capability/1
├── dialect/
│   ├── text.ex                # Text behaviour (handle_body/3, handle_event/2, ...)
│   ├── decision.ex            # Decision behaviour (handle_body/3, handle_response/3, ...)
│   ├── decision/answers.ex    # Shared answer matching for decision dialects (internal)
│   └── thinking.ex            # Shared :thinking resolution (clamping, budgets)
└── dialects/
    ├── anthropic_messages.ex  # text
    ├── google_gemini.ex
    ├── ollama_chat.ex
    ├── openai_completions.ex
    ├── openai_responses.ex
    ├── openai_decisions.ex    # decision
    └── system_one.ex

lib/mix/tasks/
├── omni.snapshot.ex           # Writes the models.dev snapshot to priv/models/
└── omni.verify.ex             # mix omni.verify <provider> <model>

priv/verify/                   # Verify assets: logo.png, whitepaper.pdf
scripts/verify/
├── sweep.exs                  # The model matrix; runs Omni.Verify over it
└── results/                   # YYYY-MM-DD.json + .md, committed
```
