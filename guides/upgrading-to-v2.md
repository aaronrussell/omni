# Upgrading to v2

Omni 2 changes how providers are configured and adds a second kind of request, decisions. The functions you call most (`Omni.generate_text/3`, `Omni.stream_text/3`, contexts, messages, tools, streaming) work as they did.

For most apps the upgrade is a config change and perhaps a line or two of code, all of it under [What to change](#what-to-change). The rest of the page is for when a result looks different, and for anyone who wrote their own provider module, dialect or source.

## What's new

- **Decisions.** `Omni.decide/3` asks decision models typed questions and returns probabilities. See [Decisions](decisions.md).
- **Any catalog provider loads by id.** Every provider in models.dev can be loaded with `providers: [:builtins, :deepseek]`, with no module to write. Custom providers need only config.
- **New built-in providers.** Mistral (`:mistral`), Together AI (`:togetherai`), xAI (`:xai`) and TypeSafe (`:typesafe`).
- **String model references.** `"anthropic:claude-sonnet-5-5"` works wherever `{:anthropic, "claude-sonnet-5-5"}` does.
- **Thinking that follows each model.** Effort levels are translated per model from catalog data, and reasoning is sent back on later turns across far more providers.
- **`mix omni.verify`.** Runs live requests against one model to check it works with your config.
- **More control over model loading.** `filter:` and `transform:` under `config :omni, :models`, and per-provider `models:` to add or correct models.

## What to change

Omni checks your config at startup. Every v1 form, and any key it doesn't know, raises with a message that gives the replacement. The quickest way through is to upgrade, boot, and fix what it reports.

### Config

| v1 | v2 |
| --- | --- |
| `config :omni, Omni.Providers.Anthropic, ...` | `config :omni, :providers, anthropic: [...]` |
| `providers: [Omni.Providers.Anthropic]` | `providers: [:anthropic]` |
| `base_url: "http://gpu-box:11434"` | `host: "http://gpu-box:11434"` |

Put together:

```elixir
# v1
config :omni, :models, providers: [Omni.Providers.Anthropic, Omni.Providers.Ollama]

config :omni, Omni.Providers.Anthropic, api_key: {:system, "MY_KEY"}

config :omni, Omni.Providers.Ollama,
  base_url: "http://gpu-box:11434",
  models: ["llama3.1:8b", [id: "qwen3.5:4b", reasoning: true]]

# v2
config :omni, :models, providers: [:anthropic, :ollama]

config :omni, :providers,
  anthropic: [api_key: {:system, "MY_KEY"}],
  ollama: [
    host: "http://gpu-box:11434",
    models: ["llama3.1:8b", [id: "qwen3.5:4b", thinking: true]]
  ]
```

- A provider is named by its id everywhere: its models.dev catalog key in snake case (`:anthropic`, `:moonshotai`, `:ollama_cloud`). `:builtins` still names every built-in.
- `host:` is an origin: scheme, host and port, with no path. If your v1 `base_url` had a path, such as a proxy's, set the whole URL on the provider's endpoint, as [URLs](providers-and-models.md#urls) shows.

### Code

| v1 | v2 |
| --- | --- |
| `thinking: %{effort: :high, budget: 20_000}` | `thinking: 20_000` |
| `Omni.put_model(:openai, model)` | `Omni.put_model(model)` |
| `base_url:` as a request option | `host:` |
| `model.provider` is a module | `model.provider` is a struct, with the id at `model.provider.id` |
| `model.dialect` | `Omni.Model.dialect(model, :text)` |
| `model.reasoning` | `model.thinking != false` |
| `Model.new(provider: Omni.Providers.OpenAI, dialect: D, reasoning: true)` | `Model.new(provider: :openai, dialects: %{text: D}, thinking: true)` |
| `Omni.Dialects.GoogleGemini` | `Omni.Dialects.GoogleGenerateContent` |

- A thinking budget is the `:thinking` value itself, with no fallback effort to give. On a model that takes effort levels, a budget becomes the smallest level that covers it, so `20_000` is `:xhigh`.
- `Omni.put_model/1` registers the model under its own provider, which must be loaded.
- `model.thinking` is `false`, `true`, or a map of what the model accepts. `Omni.Model.dialect/2` returns `{:ok, module}`, or an error for a kind of request the model doesn't serve.

## Changed behaviour

Nothing here needs a code change, but your results may differ.

- **If you track token usage or cost.** `usage.input_tokens` no longer includes cached tokens. v1 counted them in both `input_tokens` and `cache_read_tokens` on every dialect but Anthropic Messages, so totals and costs were too high. Expect lower numbers for cached requests. Gemini's `output_tokens` now include thinking tokens, which Google bills as output.
- **If you build assistant messages by hand, or store them in your own format.** Thinking now goes back only to the provider and dialect that wrote it, which fixes errors when you switch model mid-conversation. A message with no `origin` counts as another model's, so it is sent without its thinking. To keep it, store messages with `Omni.Codec`, or pass `origin: model` when you build the message.
- **If you set `:thinking` levels.** A level is translated from each model's catalog data: one the model doesn't accept is rounded to the nearest it does, and a model that takes a token budget gets one sized to the level. Some requests change as a result. The clearest case is Gemini 3, where `:high` now sends `"high"` and sent `"medium"` in v1. [Thinking](text-generation.md#thinking) has the rules.
- **If you list models.** `Omni.list_models/1` includes decision models beside text models. Filter with `Omni.Model.capability?(model, :text)`, or drop them at load with `filter:`. Realtime and image-generation models no longer load, and nor do models the `llm_db` source marks as not callable.
- **If you rely on schema validation** of tool input or `:output`. An `integer` rejects a number with a fraction, such as `1.5`, which v1 accepted. String formats other than `email` and `uri`, `date` and `date-time` among them, are sent to the model but not checked. In v1 they rejected every input.
- **If your local Ollama sits behind an authenticating proxy.** `:ollama` sends no credentials, where v1 sent a configured key as a Bearer token. Set `auth: :bearer` beside `api_key:` to get that back.

Three fixes also show in the data you get back:

- A response cut off by the token limit inside a tool use stops with `:length`. v1 reported `:tool_use` and the loop ran the tool with incomplete input.
- Moonshot, Z.ai, Alibaba, Venice, Groq and OpenCode Zen models have their earlier reasoning sent back on later turns, as OpenRouter's already did.
- OpenRouter caches Claude models when you pass `:cache`, so their usage reports cached tokens. In v1 the option did nothing for them.

## If you extended Omni

Skip this unless you wrote a provider module, a dialect or a source.

### Provider modules

First check whether you still need the module. In v1 every custom provider was one. In v2:

- A provider that models.dev lists needs nothing written: add its id to `providers:`, as in `providers: [:builtins, :deepseek]`.
- A provider it doesn't list needs only config: an endpoint, and its models.
- Most request quirks are [compat flags](providers-and-models.md#compat-flags), also set in config.

```elixir
# v1
defmodule MyApp.Providers.Acme do
  use Omni.Provider, id: :acme, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config, do: %{base_url: "https://api.acme.ai", api_key: {:system, "ACME_API_KEY"}}

  @impl true
  def models do
    [Omni.Model.new(
      id: "acme-large",
      provider: __MODULE__,
      dialect: Omni.Dialects.OpenAICompletions
    )]
  end
end

config :omni, :models, providers: [:builtins, MyApp.Providers.Acme]

# v2
config :omni, :models, providers: [:builtins, :acme]

config :omni, :providers,
  acme: [
    api_key: {:system, "ACME_API_KEY"},
    dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.acme.ai/v1"]},
    models: [[id: "acme-large", dialects: %{text: Omni.Dialects.OpenAICompletions}]]
  ]
```

The endpoint's `base_url` includes the version segment (`/v1`), and each model names its dialect: Omni no longer fills one in from the provider. [Custom providers](providers-and-models.md#custom-providers) has more.

Keep a module for what config can't express. It changes like this, and every callback is now optional:

| v1 | v2 |
| --- | --- |
| `use Omni.Provider, id: :acme, dialect: D` | `@behaviour Omni.Provider`, attached with `module: MyApp.Providers.Acme` in the provider's config |
| `config/0` returns a map with `base_url:` | `config/0` returns a keyword list, with the URL on an endpoint under `dialects:` |
| `auth_header: "x-api-key"` | `auth: {:header, "x-api-key"}` |
| `models/0` | `models/2` receives the provider's models and returns them, changed or added to |
| `modify_body/3` | `modify_body/4` also receives the model, and its input is a `%Omni.Context{}` or a `%Omni.Decision{}` |
| `build_url/2`, `authenticate/2` | Removed. URLs and auth are data on the provider. `modify_request/3` makes a last change to the request |
| `modify_events/2` | Removed. Changes to how a response is parsed belong in the dialect |
| `Omni.Provider.load([MyApp.Providers.Acme])` | `Omni.Provider.load([:acme])` |

`Omni.Provider` has the full contract.

### Dialects

- Replace `@behaviour Omni.Dialect` with `use Omni.Dialect, :text`. The text callbacks now live on `Omni.Dialect.Text`, and are unchanged except as below.
- Add `auth/0`, returning `:bearer` or `{:header, name}`: how the API takes its key.
- Add `compat_schema/0`, returning a Peri schema of the compat flags your dialect reads. Return `%{}` for none.
- `handle_event/1` is now `handle_event/2`, taking the event and the model.
- `handle_path/2` returns the resource path only (`/chat/completions`). The version segment belongs to the endpoint's `base_url`.
- To honour `:thinking`, call `Omni.Dialect.Text.resolve_thinking/2`, which applies the shared rounding and budgets.

### Sources

- `c:Omni.Source.fetch/2` takes a provider id, not a module, and the `provider_id:` option is gone.
- It returns `{:ok, provider, models}`: a partial `%Omni.Provider{}` with an endpoint for each dialect, and the models without a provider.
- `Omni.Source.build_model/1` replaces `Omni.Provider.build_model/2`. It takes `"dialects"` as a list of dialect names in place of a single `"dialect"`, and reads `"reasoning_options"` into `:thinking`.

`Omni.Source` has the full contract.
