# Omni Design Document

**Status:** Implemented (v2 branch)
**Last updated:** October 2026

---

## Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. The core challenge is managing a large, ever-changing catalog of models across many providers, where providers share a small number of underlying API formats but each has its own endpoint, authentication, and quirks.

The design separates three distinct concerns:

- **Models** -- data describing a specific LLM (capabilities, pricing, limits)
- **Providers** -- data describing a specific service: where requests go, how they authenticate, and how it deviates from the wire format it speaks
- **Dialects** -- code for the wire format of a family of APIs (how requests are built and responses are parsed)

The relationship: there are five dialects, hundreds of possible providers (13 verified built-ins; any provider in the models.dev catalog loads by id; most speak one dialect, though gateways like OpenCode Zen use several), and thousands of models (each belonging to one provider). Each `%Model{}` embeds its `%Provider{}` and names its dialect per capability (`dialects: %{text: Module}`), so dispatch is always per-model and nothing is looked up at request time.

---

## Top-Level API

### Core functions

```elixir
Omni.generate_text(model, context, opts \\ [])  # -> {:ok, %Response{}} | {:error, reason}
Omni.stream_text(model, context, opts \\ [])     # -> {:ok, %StreamingResponse{}} | {:error, reason}
```

Both functions return `{:ok, result} | {:error, reason}` because errors can occur before the request starts (model not found, invalid context/options, auth failures, bad status codes). These surface immediately at the call site rather than falling out mid-stream.

Alongside them: `get_model/2`, `list_models/1`, `put_model/1`, `get_provider/1`, and constructors (`context/1`, `message/1`, `tool/1`).

### Streaming-first design

All requests use streaming HTTP under the hood. Each dialect implements a streaming request and normalises the provider's streaming events into a unified delta format. `generate_text` is built on top of `stream_text`:

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
  base_url: "https://custom-proxy.com/v1",
  headers: %{"x-custom" => "value"},
  timeout: 300_000
)
```

The universal inference options are deliberately minimal: `max_tokens`, `temperature`, `thinking`, `cache`, `output`, `metadata`, `timeout`. A dialect may add its own through `option_schema/0` (only Anthropic Messages does, to default `max_tokens` to 4096). Validation is one strict Peri pass, so an unknown key is an error.

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

For Anthropic, the dialect places `cache_control` breakpoints on the system prompt, the tools, and the last message content block. The provider's prefix matching handles the rest -- previous messages that match the cached prefix get cache hits automatically, even as new messages are appended. Where a dialect has no mechanism, the option is silently ignored (caching is an optimisation hint, not a semantic requirement). A provider that rejects the Completions field drops it with `compat: [omit: [:cache]]`.

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

- **`provider` is the struct itself.** Within one persistent term every model of a provider shares one copy of it, so embedding costs nothing, and a `%Model{}` is self-contained: the request pipeline reads `model.provider` and `model.dialects.text` and nothing else. `Model.to_ref/1` reads `provider.id`.
- **`dialects` is keyed by capability.** `:text` is the only capability today; the map is groundwork for the Decisions API (see `context/notes/decisions-api.md`), where a model may speak a text dialect and a decision dialect.
- **`thinking`** is `false` (no reasoning), `true` (reasons, nothing more known), or a map of what the model accepts (`:efforts`, `:toggle`, `:budget`). See [Thinking](#thinking).
- Supported modalities are defined on `Omni.Model`: input `:text`, `:image`, `:pdf`; output `:text`. Anything else in catalog data is dropped.

`Model.new/1` takes `provider:` as a struct or the id of a loaded provider, fills missing `dialects` capabilities from the provider's first dialect, and accepts `thinking:` as a boolean, map, or keyword list (an empty map means `true`). It does not validate values; validation happens at the API boundary.

### Where model data comes from -- model sources

Catalog data comes from a pluggable **model source**: a module implementing the `Omni.Source` behaviour (marked experimental). A source answers one question -- *what does your catalog say about this provider?* -- in one call:

```elixir
@callback fetch(id :: atom(), opts :: keyword()) ::
            {:ok, Omni.Provider.t(), [Omni.Model.t()]} | {:error, term()}
```

It receives the provider's id and returns **raw catalog data only**:

- a partial `%Provider{}`: `id`, plus whatever the catalog knows of `name`, `base_url`, `api_key` (`{:system, var}` only when the catalog names exactly one variable -- several variables signal bespoke credentials that need config), and a provider-level `dialects` hint;
- models **without** a provider, each with `dialects` from its own catalog data, or empty when nothing maps.

Translating the id to the catalog's key is the source's job (`Omni.Sources.ModelsDev` hyphenates; `Omni.Sources.LLMDB` uses it verbatim). `Omni.Source.build_model/1` builds a model from a string-keyed map (dates, defaults, `"reasoning"` and `"reasoning_options"` into `:thinking`). Sources skip, with a warning, models they can't represent faithfully: a model whose own npm package maps to no dialect (it explicitly differs from its provider, so filling it would be a guess), and a model served from a different base URL than its provider (gateway multi-mounts; not yet supported). `{:error, :unknown_provider}` means the catalog doesn't know the id, so the provider is custom; any other error is logged and treated the same way. There is no cross-source fallback.

The npm-package-to-dialect table lives in each source. Mapping bespoke packages that are OpenAI-compatible in practice (`@ai-sdk/mistral`, `@ai-sdk/xai`, ...) belongs there too.

Omni ships two sources:

- **`Omni.Sources.ModelsDev`** (default) -- reads a snapshot of the full [models.dev](https://models.dev/) catalog bundled in the package (`priv/models/models_dev.json`, refreshed with `mix omni.snapshot` and committed to the repository). The snapshot content is verbatim; only the encoding is normalized (pretty-printed, keys sorted) so snapshot updates produce minimal, reviewable git diffs. It is transformed at load time: deprecated models and those without tool use or text modalities are filtered out, and each model's dialect is inferred from npm package metadata (the model's own package, else its provider's). The provider record supplies `name`, `api` (base URL), `env` and `npm`. Because the snapshot is unpruned, any catalog provider can be loaded by id. An optional **live mode** (`source: {Omni.Sources.ModelsDev, live: true}`) fetches fresh catalog data from models.dev at boot with a disk cache (`cache_ttl:`, `cache_dir:` opts), degrading gracefully: fresh cache → fetch → stale cache → bundled snapshot, warning at each step.
- **`Omni.Sources.LLMDB`** -- sources the catalog from the optional [`llm_db`](https://hex.pm/packages/llm_db) hex package. Selecting it without the package in deps raises at boot. Dialects come from the wire protocol, then npm metadata. Filtering and freshness are llm_db's own concerns (`config :llm_db, allow:/deny:/sources:`), deliberately not wrapped by Omni.

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
  base_url: "https://api.groq.com/openai/v1",    # includes the version segment
  api_key: {:system, "GROQ_API_KEY"},            # string | {:system, var} | {M, F, A} | nil
  auth: :dialect,                                # :bearer | {:header, name} | :none | :dialect
  headers: %{},
  dialects: %{text: [Omni.Dialects.OpenAICompletions]},  # derived from its models
  compat: %{},                                   # %{dialect_module => flags}
  module: Omni.Providers.Groq,                   # optional code for what flags can't express
  tier: :verified                                # :verified | :catalog | :custom
}
```

- **`base_url` includes the version segment** (`/v1`, `/v1beta`, `/api/paas/v4`). Dialect paths are resource paths only (`/chat/completions`, `/messages`). This follows the catalog (190 of the ~200 catalog base URLs include it) and the OpenAI SDK convention, and removed every URL-building override. Local Ollama's documented root has no version, so its dialect path stays `/api/chat`.
- **`auth` is pure data.** `:dialect` (the default) means "use the scheme of the dialect's home API" (`Dialect.auth/0`: Anthropic Messages → `x-api-key`, Gemini → `x-goog-api-key`, OpenAI → bearer). That is how a gateway like OpenCode Zen authenticates each model the way its upstream does, with no code. No function-valued forms; anything exotic goes through `modify_request/3`.
- **`dialects`** lists, per capability, every dialect the provider's models speak. It is derived at load from the models, not declared.
- **`compat`** holds compat flags keyed by dialect module. See [Compat flags](#compat-flags).
- **`tier`** records how the provider was defined. It carries no behaviour.

### Why providers are data

In v1 every provider was a module, and the module was the identity everywhere (config keys, store keys, source lookups, `Model.to_ref/1`). That meant Omni could never offer the hundreds of OpenAI-compatible endpoints in the catalog without writing hundreds of modules, and users couldn't add a provider without code even when the catalog already knew it. Auditing the modules showed two more problems:

- **`modify_body` was a post-hoc rewrite coupled to dialect internals.** Every implementation pattern-matched keys the dialect had emitted (`"reasoning_effort"`, `"response_format"`, `"max_completion_tokens"`) and undid them.
- **The dialect/provider boundary had already eroded.** The Completions dialect knew about OpenRouter, vLLM, Z.ai and Venice parsing differences. Variation was ending up in the dialect anyway, which argued for putting it there on purpose.

So providers became data, and provider quirks became **compat flags** that dialects read while encoding. Prior art (Pi in particular) showed that flags scale to hundreds of providers and that every dialect eventually needs its own set, but also that auto-detecting quirks from provider name or base URL is fragile: a user who overrides a region silently loses them. Omni's defaults therefore come from explicit per-provider data, and flags are named by wire shape, not by provider.

### Three tiers

Any provider can be loaded, but Omni promises different things about each. `tier` tells the user which promise applies.

| Tier | What it is | What Omni promises |
|---|---|---|
| `:verified` | A built-in: an id in `Omni.Provider.Builtins`, with a module in `Omni.Providers.*` | Tested against the live API, compat set, fixtures recorded, documented in its moduledoc |
| `:catalog` | Any other provider the source's catalog knows | Endpoint, key variable, models and dialect from catalog data; speaks its dialect plain, with no flags. Untested. The user sets flags, or borrows a verified set with `like:` |
| `:custom` | An id the catalog doesn't know | Nothing beyond what config defines |

**The verified list never guesses.** Flags inferred from what other libraries do are not built-in config; they are the starting point for a verification. A provider joins the verified tier only once it has been run against its live API.

### Built-in providers

Built-ins keep modules. `Omni.Provider.Builtins` (internal) maps the thirteen built-in ids to `Omni.Providers.*` modules, and each module's `config/0` *is* the verified overlay: its base URL, key variable, and compat, set explicitly even where the catalog agrees, so `like:` has a complete set to copy. Their moduledocs are the per-provider reference (quirks, regions, the flags they set). Modules carry no id; the Builtins map supplies it, and other providers attach a module with `module:` in config.

| Id | Module | Dialect | Module code beyond `config/0` |
|---|---|---|---|
| `:alibaba` | `Alibaba` | Completions | -- |
| `:anthropic` | `Anthropic` | Anthropic Messages | -- (`anthropic-version` header in `config/0`) |
| `:google` | `Google` | Gemini | -- |
| `:groq` | `Groq` | Completions | `modify_body/4`: `reasoning_format: "parsed"` |
| `:moonshotai` | `Moonshot` | Completions | -- |
| `:nearai` | `NearAI` | Completions | -- |
| `:ollama` | `Ollama` | Ollama Chat | -- (`auth: :none`, models from config) |
| `:ollama_cloud` | `OllamaCloud` | Ollama Chat | `models/2`: re-stamps every model to Ollama Chat |
| `:openai` | `OpenAI` | Responses | -- |
| `:opencode` | `OpenCode` | per model | -- |
| `:openrouter` | `OpenRouter` | Completions | -- |
| `:venice` | `Venice` | Completions | `models/2`: adds `:pdf` to every model |
| `:zai` | `Zai` | Completions | -- |

The three pieces of residual code each exist because no flag could express them:

- **Groq `modify_body/4`.** Groq's `reasoning_format` defaults to `raw` (`<think>` tags in the content) on reasoning models other than gpt-oss, which doesn't support the parameter. The module sends `"parsed"` to non-gpt-oss reasoning models unless thinking is off. It depends on the model id, so it isn't a provider-wide flag.
- **Ollama Cloud `models/2`.** The catalog describes Ollama's OpenAI-compatible endpoint; Omni uses the native chat API. Model data decides a model's dialect, so changing catalog models' dialects takes code.
- **Venice `models/2`.** Venice extracts PDF text at its API layer for every model, which the catalog doesn't record.

`anthropic-version` stays in the Anthropic module rather than a dialect header callback: other Anthropic-compatible endpoints ignore it and none require it.

### Provider ids

A provider's id is its catalog key, snake_cased: `:anthropic`, `:fireworks_ai`, `:ollama_cloud`. It is the single identity -- config keys, `get_model/2` lookup, and source catalog lookups all use it, and sources translate it to their own key format. There is no renaming and no separate catalog id. Two instances of one provider (two regions, two accounts) are not supported; call-site `base_url:` and `api_key:` cover those cases.

### Configuration

Two keys, with separate jobs: **`:models` selects** what loads, **`:providers` configures** by id. Configuring a provider never enables it, so "does setting compat turn a provider on?" has a plain answer: no. Disabling a built-in is listing `providers:` without `:builtins`.

```elixir
config :omni, :models,
  providers: [:builtins, :fireworks_ai, :gpu_box],   # default [:builtins]
  source: Omni.Sources.ModelsDev,
  filter: {MyApp.Models, :keep?}

config :omni, :providers,
  anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}],
  zai_coding_plan: [compat: [like: :zai]],
  ollama: [models: ["llama3.1:8b", [id: "qwen3.5:4b", context_size: 32_768, thinking: true]]],
  openai: [models: [[id: "ft:gpt-4o:acme::abc123", context_size: 128_000]]],
  gpu_box: [
    base_url: "http://gpu-box:8000/v1",
    dialects: %{text: Omni.Dialects.OpenAICompletions},
    auth: :none,
    models: ["llama-3.3-70b"]
  ]
```

- **`:models` keys:** `providers` (ids; `:builtins` expands to every built-in and may sit in the list), `source`, `filter`.
- **`:providers` keys:** `name`, `base_url`, `api_key`, `auth`, `headers`, `dialects`, `compat`, `module`, `models`, `source`. Unknown keys are boot errors, including in entries for providers that aren't loaded.
- **Dialects are module names** in config. A user's own dialect works with no registration. String ids (`"openai_completions"`) are an internal detail for reading catalog data (`Omni.Dialect.get/1`).
- **`models:`** adds models (ids or `Model.new/1` keyword lists) alongside the catalog's; a matching id replaces the catalog model. A custom provider and local Ollama have nothing else. Removal is the filter's job.
- **`filter:`** is a predicate over each finished `%Model{}` (provider embedded), run at load, including config-defined models. It is `{Mod, :fun}` or a named capture, because anonymous functions don't survive compile-time config.
- **v1 config raises** at boot with a migration message: per-module keys (`config :omni, Omni.Providers.X`), the old `:providers` list, modules in `providers:`, `auth_header:`.

**One merge rule.** A provider is built from three layers, later winning: source data ← module `config/0` ← app config (← call-site opts, at request time). Values without identity replace. Collections with identity merge shallowly by key: `headers` by header name, `dialects` by capability, `models` by model id, `compat` by dialect and then by flag. Keyword lists in config are maps in disguise and are normalised before merging. Within compat, `omit` and `extra_body` values replace rather than merge.

### Assembly and loading

`Omni.Application` calls `Omni.Provider.Loader.boot/0` at startup, which validates app config and loads the selected providers synchronously, so models exist before any user code runs. The empty supervisor `start/2` returns is just the OTP contract. `Omni.Provider.load/1` loads more at runtime (ids, or `{id, opts}` with inline config); loading an id that is already loaded replaces its provider and models, and models obtained earlier keep the provider struct they were built with. Because config is baked in at load, changing it after boot means reloading.

For each provider id the Loader:

1. Resolves the module: config `module:`, else the built-in.
2. Fetches catalog data from the source. An id the catalog doesn't know starts empty (`:custom`).
3. Merges the provider: source ← module `config/0` ← app config. Config `models:` merge with source models by id.
4. Passes models through the module's `models/2`.
5. Resolves dialects. **Model data decides each model's dialect.** A model with none takes the first of the provider's own configured dialects; with none configured, the one dialect all its other models share, if there is exactly one; otherwise it stays unresolved. The provider's list is its own plus its models'. A configured `dialects:` therefore only fills gaps -- it never changes a model that already has one.
6. Resolves compat: each layer's flags (module, then app config) keyed by dialect, now that the dialects are known, and validates them against each dialect's `compat_schema/0`.
7. Fills defaults (`auth: :dialect`, name from id, tier), validates, skips unresolved models with a warning, stamps the provider onto every model, applies the filter, and stores.

`Loader.assemble/2` runs steps 1-7 without touching the store, which is what tests use. A load pass runs inside `Omni.Source.with_cache/1`, a pass-scoped cache (process dictionary): sources memoize shared expensive work (the ~9 MB decoded snapshot) with `Omni.Source.memo/2`, computed once per pass and garbage collected when it ends.

**Nothing is guessed.** A wrong dialect produces confusing errors far from the cause, so refusing beats defaulting:

| Condition | Result |
|---|---|
| No base URL (catalog has none, or provider is custom) | Raise: "set `base_url:`" |
| Models, but no dialect for any of them | Raise: "set `dialects:`" |
| Unknown or invalid compat flag; flat flags on a multi-dialect provider | Raise |
| v1-style config | Raise with migration message |
| No models | Warning |
| Some models with no resolvable dialect | Skipped with a warning |
| No API key | Not an error -- a key can be passed per request; a request without one returns `{:error, :no_api_key}` |

### Provider modules

A provider module declares `@behaviour Omni.Provider`. Every callback is optional and skipped when not defined:

| Callback | When | Purpose |
|---|---|---|
| `config/0` | Load | Keyword overrides over source data: base URL, key, auth, headers, dialects, compat |
| `models/2` | Load | Receives the merged models and provider; returns the final list (Venice, Ollama Cloud) |
| `modify_body/4` | Request | `(body, model, context, opts)` after the dialect builds the body. Receives the model, so it can vary by model (Groq) |
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

A dialect is a module implementing a behaviour. It defines the wire format for a family of APIs -- how to build request bodies, construct URL paths, and parse streaming events. A dialect is pure data transformation with no knowledge of HTTP or configuration. It knows about providers only through the compat flags it declares.

### The role of a dialect

A dialect answers the question: **"What does this API family expect to receive, and what does it send back?"**

Given Omni's internal types (Context, Messages, Content blocks, Tools, options), a dialect knows how to reshape them into the JSON structure a particular API family expects. And given streaming events coming back, it knows how to interpret them as Omni's normalised deltas. A dialect has no concept of "where" the API lives or "who" is calling it. It's a bidirectional translator between Omni's world and a wire format.

The separation from providers exists because many providers share the same wire format. The OpenAI Chat Completions dialect is written and tested once, and each provider that speaks it is a struct with a base URL, a key, and perhaps a few compat flags.

### The dialects

| Module | String id | Home API | Auth |
|---|---|---|---|
| `OpenAICompletions` | `"openai_completions"` | OpenAI Chat Completions; spoken by most third-party providers | bearer |
| `OpenAIResponses` | `"openai_responses"` | OpenAI Responses | bearer |
| `AnthropicMessages` | `"anthropic_messages"` | Anthropic Messages | `x-api-key` |
| `GoogleGemini` | `"google_gemini"` | Gemini `streamGenerateContent` (model id in the path) | `x-goog-api-key` |
| `OllamaChat` | `"ollama_chat"` | Ollama native `/api/chat` (NDJSON) | bearer |

String ids exist for catalog data; `Omni.Dialect.get/1` resolves them. Config uses modules.

### Dialect behaviour callbacks

| Callback | Returns | Purpose |
|----------|---------|---------|
| `option_schema/0` | `map()` | Peri schema of dialect-specific options, merged with the universal schema |
| `compat_schema/0` | `map()` | Peri schema of the compat flags the dialect understands (`%{}` for none) |
| `auth/0` | `:bearer \| {:header, name}` | The home API's key scheme, used when a provider's `auth` is `:dialect` |
| `handle_path/2` | `String.t()` | Resource path for the model and opts, appended to `base_url` |
| `handle_body/3` | `map()` | Builds the request body from model, context, and validated options |
| `handle_event/2` | `[delta]` | Parses one decoded stream event into delta tuples; receives the model |

**No callback returns ok/error tuples.** Option validation happens at the API boundary before any dialect callback runs, so dialects receive validated options and operate on known-good data. `handle_event/2` returns a list (empty to skip). Dialect output (the request body) is not validated at runtime; a malformed body is a library bug caught by tests.

### Dialect callback details

**`handle_path/2`** -- returns the resource path. The version segment belongs to `base_url`:

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

Options are validated once, early, in `Request.validate/2`. The schema is the universal schema in `Omni.Request` (inference options plus type-loose config keys: `api_key`, `base_url`, `headers`, `plug`) merged with `dialect.option_schema/0`. The provider's `base_url`, `api_key` and `headers` are merged under the call-site opts first, then the whole map is validated in one strict Peri pass (unknown keys rejected, catching typos). Loop options (`raw`, `max_steps`, `tool_timeout`) are taken by `Omni.Loop` before this, and `output` is read by both. All downstream callbacks receive the one validated map.

### Compat flags

Compat flags describe how a provider deviates from the API its dialect is named after. They are the main mechanism for provider variation, and dialects are their single home.

#### Rules

- **No flag means the home API's behaviour.** With no flags, the Completions dialect behaves exactly like OpenAI's own Chat Completions API. A flag exists only to describe a deviation. No flag takes `nil`; absence is the default. A catalog-tier provider "speaks the dialect plain": no flags.
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
- **Ship rule.** A flag ships only with a verified provider that uses it. Prior art says which flags to expect; only a live endpoint proves a flag works. The flag set grows with the verified list, not ahead of it.

The Completions flag table, with what each value does on the wire, is in the `Omni.Dialects.OpenAICompletions` moduledoc. The other four dialects have empty `compat_schema/0`s: no verified provider needs a flag on them yet. That is the ship rule, not a claim that catalog providers speaking them need nothing.

#### Built-in flags

All on `Omni.Dialects.OpenAICompletions`. Anthropic, Google, OpenAI, OpenCode, Groq and both Ollamas set none.

| Provider | Flags | Why |
|---|---|---|
| Alibaba | `thinking_toggle_format: :enable_thinking`, `thinking_budget_field: "thinking_budget"`, `output_format: :json_object` | Switches thinking with `enable_thinking` and takes a budget; strict `json_schema` is turned into JSON mode server-side and then fails, so JSON mode with the schema in the prompt is used |
| Moonshot | `thinking_toggle_format: :thinking_type` | `thinking: {type: ...}` on toggle models. `max_completion_tokens` is honoured; `reasoning_content` replay was not needed in tool loops |
| NearAI | `max_tokens_field: "max_tokens"`, `omit: [:cache, :thinking, :strict_schema]` | Ported from v1; not verified live (no key) |
| OpenRouter | `thinking_effort_field: "reasoning.effort"`, `thinking_replay_field: "reasoning_details"` | Nested effort; `reasoning_details` must round-trip in multi-turn |
| Venice | `thinking_toggle_format: :reasoning_enabled` | Venice recommends `reasoning: {enabled: false}` over `reasoning_effort: "none"` |
| Z.ai | `max_tokens_field: "max_tokens"`, `thinking_toggle_format: :thinking_type`, `output_format: :json_object`, `attachment_format: :file_url` | Ignores `max_completion_tokens`; no JSON Schema constraints; files as `file_url` parts |

`like: :zai` copies a built-in's whole compat map (all dialects); the layer's own flags overlay it. It copies compat only -- not module, base URL or key.

#### Where compat lives

Compat lives on the provider only, keyed by dialect module. Models carry no compat; they pick a dialect per capability, and the dialect reads that dialect's flags from the provider:

```elixir
compat = model.provider.compat[model.dialects.text]   # what Dialect.compat/2 does
```

This handles every provider shape with no special case: a single-dialect provider has one key; a gateway (OpenCode) has one key per dialect its models speak; a future decision dialect is another key. In config, a flat keyword list is sugar for "my single dialect" and is an error on a multi-dialect provider.

Per-model compat was ruled out because what looked like per-model variation resolves elsewhere:

| Variation | Resolved by |
|---|---|
| Effort levels differ per model (Groq); effort vs toggle models on one provider (Moonshot, Z.ai, Alibaba) | Model capability data (`Model.thinking`) |
| One model needs another dialect's wire shape (OpenRouter's `anthropic/*` cache control) | Routing that model over a different dialect (not yet built) |
| Anything genuinely per-model that remains | Module code, which sees the model (Groq `modify_body/4`) |

The cost: `extra_body` is provider-wide and unconditional. A field only some models accept is module code.

#### Parse tolerantly, encode by flag

No library surveyed uses flags to parse Completions streams, and Omni doesn't either. The Completions parser is a union: `reasoning_content` or `reasoning`, every known finish reason (including Z.ai's), packed chunks (Venice), in-stream errors. All variation is on the encode side.

The one parse-side read of compat is capture for replay: with `thinking_replay_field: "reasoning_details"`, the dialect stashes `reasoning_details` into `Message.private` while parsing and sends them back on that assistant message when encoding. Capture and replay share the flag, so data is only collected when it will be sent back. That is why `handle_event/2` receives the model.

Not adopted: a stateful parse hook (init, per-event state, flush) for reasoning streamed inline as `<think>` tags. No verified provider needs it.

### Thinking

The `:thinking` option is translated per model, from capability data, not from model-name prefixes. Every library surveyed that models reasoning limits well splits *how an endpoint spells reasoning* (wire format -- dialect and compat) from *which levels a model accepts* (a fact about the model -- model data). Libraries that hard-code model-id patterns call that their weak spot.

#### Model data

`Model.thinking` is `false | true | %{efforts, toggle, budget}`, filled by sources from models.dev `reasoning_options` (`{type: "effort", values}`, `{type: "toggle"}`, `{type: "budget_tokens", min, max}`); llm_db passes those through and falls back to OpenRouter's `supported_efforts`.

- `:efforts` -- the values the model takes, as **wire strings** (`"none"`, `"minimal"`, `"default"`, `"low"`, ...), never atoms. `"none"` means it can be switched off.
- `:toggle` -- `true` when thinking switches on and off as a whole.
- `:budget` -- `{min, max}` when the model takes a token budget; either bound may be `nil`.
- `true` means the model reasons and nothing more is known (the catalog's empty list normalises to `true`); dialects fall back to their plain encoding.

#### Resolution (`Omni.Dialect.Thinking`)

Shared by all five dialects and public, so custom dialects agree too. `resolve(model, option)` returns:

- `nil` -- send nothing: option unset, model doesn't reason, or off requested on a model whose data shows no way to switch off.
- `:off` -- switch off (toggle, `"none"` in efforts, or no data).
- `:dynamic` -- `thinking: true`: on, the model decides. A dialect with no native dynamic mode resolves `:medium` instead.
- `%{level, effort, budget}` -- on. `effort` is the model's value for the level, or `nil` with no effort list. `budget` is set when the model has a budget range or no data at all.

Rules:

- **One ladder:** `minimal < low < medium < high < xhigh < max`. A level clamps to the model's efforts: round up to the nearest supported value, else down. On never crosses into off.
- **`"default"`** is sent for any "on" request when it is the model's only "on" value (Groq Qwen).
- **Budgets** come from one table -- low 1024, medium 4096, high 16384, xhigh 24576, max 32768 -- clamped to the model's range. `%{effort:, budget:}` sets an exact budget, on budget models only; elsewhere its effort applies.

#### Per-dialect encoding

| Dialect | Encoding |
|---|---|
| OpenAI Completions | **Off:** the `thinking_toggle_format` spelling if set, else `"none"` at `thinking_effort_field`. **On, model has efforts:** the effort at `thinking_effort_field`, even when a toggle format is set. **On, no efforts:** the toggle if set (plus a budget at `thinking_budget_field` when set and the model takes one), else the level's effort string. `omit: [:thinking]` sends nothing |
| OpenAI Responses | `reasoning.effort` (clamped), `"none"` for off, `summary: "auto"`. Dynamic resolves `:medium`. With no data, `:max` sends `"xhigh"` |
| Anthropic Messages | **Efforts and no budget range** (Claude 5, Opus 4.7+): adaptive (`thinking.type: "adaptive"`, plus `output_config.effort` unless dynamic). **Budget range, or no data:** `enabled` with `budget_tokens`, added to `max_tokens`; dynamic resolves `:medium`. **Off:** `disabled`. Temperature is dropped when thinking is on |
| Google Gemini | **Efforts** (Gemini 3): `thinkingLevel` matched by name; dynamic sends no level. **Budget or no data** (Gemini 2.5): `thinkingBudget`; dynamic is `-1`. **Off:** `thinkingBudget: 0`, only where the model can be switched off |
| Ollama Chat | **Efforts:** the clamped string (dynamic resolves `:medium`). **Toggle or no data:** boolean |

Older models need not be perfect: Opus 4.5 and 4.6 moved from adaptive to budget thinking when their hard-coded prefix list went. Anthropic's `@strict_sampling_prefixes` (Opus 4.7 rejects non-default sampling) is unrelated to thinking and stays.

### Testability

Each layer is testable independently:

```elixir
# A dialect in pure isolation -- no HTTP, no provider store
body = AnthropicMessages.handle_body(model, context, opts)
assert body["messages"] == [...]

deltas = AnthropicMessages.handle_event(%{"type" => "content_block_delta", ...}, model)
assert deltas == [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}]

# A compat flag: build a model whose provider carries it
model = Fixtures.model(provider: [compat: %{OpenAICompletions => %{max_tokens_field: "max_tokens"}}])
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
    private: %{}      # provider-specific opaque round-trip data
  ]

  def new(attrs) do
    struct!(__MODULE__, Map.put_new_lazy(attrs, :timestamp, &now/0))
  end

  defp now, do: DateTime.utc_now()
end
```

`private` holds data a dialect captures while parsing and must send back when encoding the same message later -- OpenRouter's `reasoning_details` is the current example. Keys are flat atoms; dialects write and read them, users don't. Provider-specific data goes here, not on content blocks.

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

Token counts are extracted from the provider's API response. Costs are derived by multiplying token counts against the pricing data on the `%Model{}` struct (cost per million tokens for each tier).

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
  defstruct [:text, :signature, :redacted_data]
end
```

Represents a model's reasoning/thinking output. The `signature` field is used by Anthropic to verify thinking block authenticity when they're passed back in multi-turn conversations. `redacted_data` holds Anthropic's encrypted redacted thinking, which must be sent back verbatim; when it is present, `text` is `nil`.

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
| `Content.Thinking` | text, signature, redacted_data | Assistant messages |
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

## Request Flow

### The stream_text pipeline

`Omni.stream_text/3` resolves a `{provider_id, model_id}` tuple to a `%Model{}`, coerces the context with `Context.new/1`, and hands both to `Omni.Loop.stream/3`. The loop owns multi-step behaviour; `Omni.Request` owns one request. The code below is illustrative, not the exact implementation:

```elixir
# In Omni.Request:
def build(%Model{provider: provider} = model, context, opts) do
  dialect = model.dialects.text

  with {:ok, opts} <- validate(model, opts),
       :ok <- validate_context(model, context) do
    url = opts.base_url <> dialect.handle_path(model, opts)

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

- **Everything comes from the model.** The dialect is `model.dialects.text`; base URL, key, auth, headers, compat and module are on `model.provider`. Nothing is looked up at request time.
- **`validate/2` is a two-tier merge plus one strict pass.** The provider's `base_url`, `api_key` and `headers` sit under the call-site opts (headers merge by key), and the merged map is validated against the universal schema plus `dialect.option_schema/0`. Every callback receives the one validated map, config and inference options together.
- **`validate_context/2`** rejects attachments whose media type the model's `input_modalities` don't cover, before anything is sent.
- **Auth is data.** `auth_scheme/2` maps `:dialect` (and an unset value, for hand-built structs) to `dialect.auth/0`; `:none` sends nothing; `:bearer` and `{:header, name}` resolve the key with `Provider.resolve_auth/1`, returning `{:error, :no_api_key}` when there is none. `modify_request/3` runs after, so it can overwrite anything.
- **`:timeout` with a generous default.** Defaults to 300,000ms (5 minutes), mapped to Req's `receive_timeout`. LLM APIs routinely exceed Req's default 15s, especially thinking models.
- **Status check catches HTTP errors early.** Non-200 responses are read and turned into `{:error, {:http_error, status, body}}` before any streaming begins.
- **The event stream is lazy composition.** `resp.body` is a `Req.Response.Async` enumerable of raw chunks; the parser turns them into JSON maps and the dialect into deltas. Nothing executes until the consumer drives the stream.
- **`validate/2`, `parse_event/2` and `validate_context/2` are `@doc false` public functions**, exposed for unit tests. The module's API is `build/3` and `stream/3`.
- **StreamingResponse is generic.** It receives delta tuples and builds the consumer pipeline via `Stream.transform/5`; it has no knowledge of providers, dialects, or HTTP.

### The loop

`Omni.Loop` turns one or more requests into a single `StreamingResponse`. It pops `:raw`, `:max_steps` (default `:infinity`) and `:tool_timeout` (default 30s), then streams the first step. Each step's events pass through to the consumer; when a step's `:done` arrives, a recursive `Stream.flat_map` either emits the terminal event or returns the next step's lazy stream:

- **Tool auto-execution.** If the response has tool use blocks and every named tool has a handler, `Tool.Runner` executes them in parallel, emits a `:tool_result` event per result, pushes the assistant message and a user message of `ToolResult` blocks onto the context, and streams the next step. A tool with no handler (schema only) ends the loop so the caller can handle it. A hallucinated tool name gets an error result sent back, and the loop continues. `:max_steps` caps the rounds; `1` disables looping.
- **Structured output.** With `:output` set, the final text is JSON-decoded and validated against the schema into `response.output`. On failure the loop sends the error back and retries, up to 3 times. A `:length` stop is not retried.

The final `%Response{}` carries every message from every step in `messages`, cumulative `usage`, and one `raw` tuple per step.

### High-level flow diagram

```
Omni.stream_text(model, context, opts)
├── 1. Resolve model ({provider_id, model_id} → %Model{}, via the store)
├── 2. Coerce context (Context.new/1)
└── 3. Loop.stream(model, context, opts)
      ├── Pop :raw, :max_steps, :tool_timeout
      ├── Request.build(model, context, opts)
      │     ├── validate: provider base_url/api_key/headers <- call-site opts; one strict Peri pass
      │     ├── validate_context: attachment media types vs model modalities
      │     ├── url  = base_url <> dialect.handle_path(model, opts)
      │     ├── body = dialect.handle_body(model, context, opts)   (reads provider compat)
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

## Module Structure

```
lib/omni.ex                    # Top-level API: generate_text, stream_text, get_model,
                               #   list_models, put_model, get_provider, constructors
lib/omni/
├── application.ex             # Boots Omni.Provider.Loader at startup
├── model.ex                   # Model struct, new/1, get/list/put, to_ref/1
├── context.ex                 # Context struct, new/1, push/2
├── message.ex                 # Message struct (role, content blocks, timestamp, private)
├── response.ex                # Response struct (message envelope with metadata)
├── streaming_response.ex      # StreamingResponse struct, Enumerable impl,
│                              #   on/3, text_stream/1, complete/1, cancel/1
├── usage.ex                   # Usage struct, add/2, sum/1
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
├── request.ex                 # Request orchestration: build/3, stream/3,
│                              #   validate/2, parse_event/2, validate_context/2
├── loop.ex                    # Recursive stream loop (tools, structured output retries)
├── provider.ex                # Provider struct, module behaviour, get/1, load/1,
│                              #   builtins/0, resolve_auth/1
├── provider/
│   ├── builtins.ex            # Built-in ids → Omni.Providers.* modules
│   └── loader.ex              # Assembly, merging, validation, store, boot config checks
├── providers/
│   ├── alibaba.ex             # One module per built-in: config/0 is the verified
│   ├── anthropic.ex           #   overlay; moduledoc is the provider reference
│   └── ...
├── source.ex                  # Source behaviour, build_model/1, pass-scoped cache
│                              #   (with_cache/1, memo/2)
├── sources/
│   ├── models_dev.ex          # Default source: bundled models.dev snapshot + live mode
│   └── llmdb.ex               # Optional source backed by the llm_db package
├── dialect.ex                 # Dialect behaviour, string registry (get/1), compat/2
├── dialect/
│   └── thinking.ex            # Shared :thinking resolution (clamping, budgets)
└── dialects/
    ├── anthropic_messages.ex
    ├── google_gemini.ex
    ├── ollama_chat.ex
    ├── openai_completions.ex
    └── openai_responses.ex
```
