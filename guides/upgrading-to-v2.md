# Upgrading to v2

Omni 2 changes how providers are configured and adds a second kind of request, decisions. The functions you call most (`Omni.generate_text/3`, `Omni.stream_text/3`, contexts, messages, tools, streaming) work as they did. Most apps need to change their config and little else.

Work through this page in order. The first three sections apply to nearly everyone. The later ones apply only if you wrote your own provider module, dialect or source.

Omni checks your config at startup. v1 config raises with a message that names the new form, so the quickest way through is often to upgrade, boot, and fix what it reports.

## What's new

- **Decisions.** `Omni.decide/3` asks decision models typed questions and returns probabilities. See [Decisions](decisions.md).
- **Any catalog provider loads by id.** Every provider in models.dev can be loaded with `providers: [:builtins, :deepseek]`, with no module to write. Custom providers need only config.
- **New built-in providers.** Mistral (`:mistral`), Together AI (`:togetherai`), xAI (`:xai`) and TypeSafe (`:typesafe`).
- **String model references.** `"anthropic:claude-sonnet-5-5"` works wherever `{:anthropic, "claude-sonnet-5-5"}` does.
- **Thinking that follows each model.** Effort levels are translated per model from catalog data, and reasoning is sent back on later turns across far more providers.
- **`mix omni.verify`.** Runs live requests against one model to check it works with your config.
- **More control over model loading.** `filter:` and `transform:` under `config :omni, :models`, and per-provider `models:` to add or correct models.

## 1. Update your config

### Provider config is keyed by id

Provider config moves from the provider's module to its id, under `:providers`:

```elixir
# v1
config :omni, Omni.Providers.Anthropic, api_key: {:system, "MY_KEY"}

# v2
config :omni, :providers, anthropic: [api_key: {:system, "MY_KEY"}]
```

A provider's id is its models.dev catalog key in snake case (`:anthropic`, `:moonshotai`, `:ollama_cloud`). The same goes for a per-provider source: `config :omni, :providers, openai: [source: ...]`.

### The providers list takes ids

```elixir
# v1
config :omni, :models, providers: [Omni.Providers.Anthropic, Omni.Providers.OpenAI]

# v2
config :omni, :models, providers: [:anthropic, :openai]
```

`:builtins` still names every built-in and may sit in the list with others. Configuring a provider under `:providers` never loads it; only this list does.

### `base_url` becomes `host` or an endpoint

A provider no longer has one `base_url`. It has an endpoint for each dialect it serves, each with its own URL. For the common case of the same API at another address, set `host:`, an origin with no path:

```elixir
# v1
config :omni, Omni.Providers.Ollama, base_url: "http://gpu-box:11434"

# v2
config :omni, :providers, ollama: [host: "http://gpu-box:11434"]
```

To set a whole URL, path included, set it on the endpoint:

```elixir
# v1
config :omni, :providers,
  gpu_box: [base_url: "http://gpu-box:8000/v1", dialects: %{text: Omni.Dialects.OpenAICompletions}]

# v2
config :omni, :providers,
  gpu_box: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]}]
```

An endpoint's `base_url` includes the version segment (`/v1`). The `:base_url` request option is gone too: pass `host:` to send one request elsewhere.

### `auth_header` becomes `auth`

```elixir
# v1
auth_header: "x-api-key"

# v2
auth: {:header, "x-api-key"}
```

The values are `:bearer`, `{:header, name}`, `:none` and `:dialect`. The default, `:dialect`, sends the key the way the dialect's own API does.

### Custom providers and their models

A custom provider's models each name their dialect, by capability:

```elixir
config :omni, :providers,
  gpu_box: [
    dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]},
    auth: :none,
    models: [[id: "llama-3.3-70b", dialects: %{text: Omni.Dialects.OpenAICompletions}]]
  ]
```

Omni no longer fills in a model's dialect from its provider. A config model with no dialect raises at startup.

### Local Ollama

Local Ollama's models are listed under its provider config, and it sends no credentials:

```elixir
config :omni, :providers, ollama: [models: ["llama3.1:8b", "qwen3.5:4b"]]
```

In v1 a configured key was sent as a Bearer token. If your Ollama sits behind an authenticating proxy, set `auth: :bearer` and `api_key:`.

### Unknown keys are errors

Config is validated at startup, including entries for providers that aren't loaded. The keys a provider takes are `name`, `host`, `api_key`, `auth`, `headers`, `dialects`, `module`, `models` and `source`. [Providers and models](providers-and-models.md) covers each.

## 2. Update your code

### Thinking budgets are integers

A token budget is now the `:thinking` value itself. The map form is gone:

```elixir
# v1
Omni.generate_text(model, context, thinking: %{effort: :high, budget: 20_000})

# v2
Omni.generate_text(model, context, thinking: 20_000)
```

On a model that takes effort levels, a budget becomes the smallest level whose budget covers it (`20_000` is `:xhigh`), so there is no separate fallback effort to give.

### `%Omni.Model{}`

| v1 | v2 |
| --- | --- |
| `model.provider` is a module | `model.provider` is an `%Omni.Provider{}` struct; its id is `model.provider.id` |
| `model.dialect` is a module | `model.dialects` is a map by capability: `%{text: Module}`, `%{decision: Module}` or both |
| `model.reasoning` is a boolean | `model.thinking` is `false`, `true`, or a map of what the model accepts |

Where you read `model.reasoning`, read `model.thinking != false`. To get a model's dialect, use `Omni.Model.dialect/2`.

`Omni.Model.new/1` takes `thinking:` in place of `reasoning:`, takes `provider:` as a loaded provider's id or struct, and needs `dialects:`.

### `Omni.put_model/1`

`Omni.put_model/2` is now `Omni.put_model/1`. The model is registered under its own provider, which must be loaded.

### `Omni.list_models/1` includes decision models

Providers that serve decision models list them beside their text models. If your code assumes every model generates text, filter with `Omni.Model.capability?(model, :text)`, or drop decision models at load with `filter:`.

### Errors

- `{:error, {:unknown_provider, id}}` now covers both a provider that doesn't exist and one that isn't loaded.
- A missing endpoint URL is a request-time error, `{:error, {:no_base_url, dialect}}`, not a boot error.
- A request to a model that doesn't serve that kind of request returns `{:error, {:unsupported_capability, :text | :decision}}`.

### Renamed dialect

`Omni.Dialects.GoogleGemini` is now `Omni.Dialects.GoogleGenerateContent`. Update any config or code that names it.

## 3. Check for changed behaviour

These need no code change, but your results may differ.

**Thinking levels follow each model.** A level the model doesn't accept is rounded to the nearest it does, and models that take a token budget get one sized to the level (low 1024, medium 4096, high 16384, xhigh 24576, max 32768). `thinking: false` sends nothing to a model that can't switch thinking off. Some requests change as a result:

- Gemini 3 levels match by name, so `:high` now sends `"high"` where it sent `"medium"`.
- Claude Opus 4.6 and Sonnet 4.6 use budget thinking. The Claude 5 family and Opus 4.7 and later use adaptive thinking.
- Moonshot, Z.ai and Alibaba models that list effort levels are sent an effort, not the provider's on/off switch.

**Thinking goes back only to the model family that wrote it.** An assistant message is sent with its thinking only to the provider and dialect that produced it. This fixes errors when switching model mid-conversation. It also means assistant messages you build by hand, or restore from your own storage format, lose their thinking on replay because they carry no origin. To keep it, store messages with `Omni.Codec`, or set `origin:` when you build the message.

**Cached tokens are counted once.** `usage.input_tokens` no longer includes cached tokens on any dialect. In v1 the OpenAI, Gemini and Ollama dialects counted them in both `input_tokens` and `cache_read_tokens`, so totals and costs were too high. Expect lower numbers for cached requests on those providers.

**A response cut short stays cut short.** A response that hits the token limit inside a tool use now stops with `:length`. In v1 it reported `:tool_use` and the loop ran the tool with incomplete input.

**More Completions providers get their reasoning back.** Moonshot, Z.ai, Alibaba, Venice, Groq, Together and OpenCode Zen now send earlier reasoning back on later turns, as OpenRouter already did.

**OpenRouter caches Claude models** when you pass `:cache`. In v1 the option did nothing for them.

**Schema validation is stricter in one place and looser in another.** An `integer` schema now rejects a number with a fraction, such as `1.5`, which v1 accepted. String formats other than `email` and `uri`, including `date` and `date-time`, are sent to the model but no longer checked: in v1 they rejected every input. `Omni.Schema.validate/2` lists what the built-in validator checks.

**Some models no longer load.** The catalog now holds chat and decision models only, so realtime models and image-generation models have gone. On the `llm_db` source, models it marks as not callable are skipped.

## 4. If you wrote a provider module

`use Omni.Provider, id: ..., dialect: ...` is gone. A provider module declares the behaviour, carries no id, and is attached in config:

```elixir
defmodule MyApp.Acme do
  @behaviour Omni.Provider

  @impl true
  def config do
    [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.acme.ai/v1"]}]
  end
end

config :omni, :providers, acme: [module: MyApp.Acme]
```

Every callback is optional:

| Callback | Does |
| --- | --- |
| `config/0` | Returns a keyword list of provider settings (`name`, `api_key`, `auth`, `headers`, `dialects`) |
| `models/2` | Receives the provider's models and returns them, changed or added to |
| `modify_body/4` | Adjusts a request body |
| `modify_request/3` | Adjusts the `%Req.Request{}` |

Removed callbacks: `build_url/2`, `authenticate/2`, `modify_events/2`, `modify_deltas/3`, `models/0`, `id/0` and `dialect/0`. URLs and auth are now data on the provider, and changes to how a response is parsed belong in the dialect.

Before you port a module, check whether you still need it. Most of what v1 modules did is now a [compat flag](providers-and-models.md#compat-flags) in config.

`modify_body/4`'s third argument is a `%Omni.Context{}` for a text request and a `%Omni.Decision{}` for a decision, so match on the struct if you read `context.messages`.

`Omni.Provider.load/1` takes ids, or `{id, opts}` pairs.

## 5. If you wrote a dialect

- Replace `@behaviour Omni.Dialect` with `use Omni.Dialect, :text`. The text callbacks now live on `Omni.Dialect.Text`, and are otherwise unchanged except as below.
- Add `auth/0`, returning `:bearer` or `{:header, name}`: how the API takes its key.
- Add `compat_schema/0`, returning a Peri schema of the compat flags your dialect reads. Return `%{}` for none.
- `handle_event/1` is now `handle_event/2`, taking the event and the model.
- `handle_path/2` returns the resource path only (`/chat/completions`). The version segment belongs to the endpoint's `base_url`.
- To honour `:thinking`, call `Omni.Dialect.Text.resolve_thinking/2`, which applies the shared rounding and budgets.

On `Omni.Dialects.OpenAICompletions`, the flag `thinking_replay_field: "reasoning_details"` is now `thinking_replay_format: :reasoning_details`.

## 6. If you wrote a source

`c:Omni.Source.fetch/2` takes a provider id, not a module, and returns `{:ok, provider, models}`: a partial `%Omni.Provider{}` with an endpoint for each dialect, and the models without a provider. `Omni.Source.build_model/1` replaces `Omni.Provider.build_model/2`, takes `"dialects"` as a list of dialect names in place of a single `"dialect"`, and reads `"reasoning_options"` into `:thinking`. `Omni.Source` has the full contract.
