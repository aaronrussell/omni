# Providers and models

Omni works with no configuration: the built-in providers load at startup, each with its models, and each reads its API key from the environment. This guide is for when you want something else: fewer providers, a provider Omni has no built-in for, a server of your own, a model the catalog lacks, or different model data.

## Three ideas

- A **model** is one LLM: its id, limits, prices, and what it can do. You name it in every request.
- A **provider** is the service that hosts models: where it lives, how to authenticate, and which APIs it serves. Each model belongs to one provider.
- A **dialect** is the wire format of an API, such as OpenAI's Chat Completions or Anthropic's Messages. Many providers speak the same dialect, and a gateway may speak several. Each model names the dialect it is reached through.

All three are plain data, built once at startup from a catalog of model data, Omni's knowledge of each built-in provider, and your config. Two config keys shape the result, and they have separate jobs. `config :omni, :models` selects what loads. `config :omni, :providers` configures providers by id.

## Choosing which providers load

By default every built-in loads. To load fewer, or more, list provider ids:

```elixir
# Only these two
config :omni, :models, providers: [:anthropic, :openai]

# Every built-in, plus two more
config :omni, :models, providers: [:builtins, :deepseek, :gpu_box]
```

A provider's id is its key in the [models.dev](https://models.dev) catalog, in snake case: `:anthropic`, `:fireworks_ai`, `:ollama_cloud`. The same id is used everywhere: in this list, in config, and in model references.

## Three kinds of provider

Any provider can be loaded, and Omni knows more about some than others.

### Built-in providers

Common providers Omni ships code for. Each is set up for its API's quirks and run against the live API before a release. [Built-in providers](built-in-providers.md) lists them.

### Catalog providers

The rest of the models.dev catalog, over two hundred of them. Add the id to `providers:` and Omni takes the provider's URL, API key variable and models from catalog data:

```elixir
config :omni, :models, providers: [:builtins, :deepseek]
```

```elixir
Omni.generate_text("deepseek:deepseek-v4-pro", "Hello!")
```

A catalog provider is spoken to in its dialect with no adjustments. Many work as they are. One that deviates from the dialect needs [compat flags](#compat-flags).

### Custom providers

Providers the catalog doesn't know, such as an inference server of your own. Define one wholly in config: an endpoint for the dialect it speaks, how it authenticates, and its models.

```elixir
config :omni, :models, providers: [:builtins, :gpu_box]

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

Whatever kind of provider serves a model, [`mix omni.verify`](#checking-a-model-works) tells you whether it works.

## Configuring a provider

Each entry under `config :omni, :providers` takes these keys. Your values are layered over the catalog's and the built-in's, so set only what you want to change.

| Key | What it sets |
| --- | --- |
| `:name` | A display name |
| `:module` | A provider module, for behaviour config can't express |
| `:host` | Another origin for the provider's URLs, such as `"http://gpu-box:11434"` |
| `:api_key` | A string, `{:system, "ENV_VAR"}`, or `{Module, :function, args}` called on each request |
| `:auth` | How the key is sent: `:bearer`, `{:header, "x-api-key"}`, `:none`, or `:dialect` (the default: the way the dialect's own API does it) |
| `:dialects` | Endpoints, by dialect module: a `:base_url` and `:compat` flags for each |
| `:headers` | Extra headers for every request |
| `:models` | Models to add or correct |
| `:source` | Where this provider's model data comes from |

An unknown key is an error at startup. A missing API key is not: you can pass `:api_key` on each request, and a request with no key returns `{:error, :no_api_key}`.

### URLs

A provider has an endpoint for each dialect it serves. The endpoint's `base_url` is the whole URL up to and including the version, and a request goes to that plus the dialect's own path:

```elixir
# dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]}
# POST http://gpu-box:8000/v1/chat/completions
```

Most of the time you want the same API somewhere else: another machine, a region, a proxy. That is `:host`, which swaps the origin (scheme, host and port) of every URL the provider has and keeps their paths:

```elixir
config :omni, :providers,
  ollama: [host: "http://gpu-box:11434"],
  alibaba: [host: "https://dashscope-us.aliyuncs.com"]
```

`:host` is also a request option, for sending one request elsewhere. To change a path, set the endpoint's `base_url` instead.

### Compat flags

Many providers speak a dialect with small differences from the API it is named after: another field name for the token limit, another way of switching thinking on. Compat flags describe those differences, one flag each, and they are set on the endpoint they apply to:

```elixir
config :omni, :providers,
  gpu_box: [
    dialects: %{
      Omni.Dialects.OpenAICompletions => [
        base_url: "http://gpu-box:8000/v1",
        compat: [max_tokens_field: "max_tokens", omit: [:cache]]
      ]
    }
  ]
```

`Omni.Dialects.OpenAICompletions` lists the flags and what each does. An unknown flag is an error at startup.

Some catalog providers mirror another provider's compat flags. `like:` copies a built-in's flags:

```elixir
config :omni, :providers,
  zai_coding_plan: [dialects: %{
    Omni.Dialects.OpenAICompletions => [compat: [like: :zai]]
  }]
```

## Models

A model reference is a provider id and a model id, as a tuple or a string. The provider id ends at the first `:` or `/`, so model ids may contain either:

```elixir
{:openrouter, "typesafe/jev-1.14"}
"openrouter:typesafe/jev-1.14"
"openrouter/typesafe/jev-1.14"
```

Use `Omni.get_model/1` and `Omni.list_models/1` to inspect loaded models:

```elixir
{:ok, model} = Omni.get_model("anthropic:claude-sonnet-5-5")

model.context_size      #=> 1000000
model.input_modalities  #=> [:text, :image, :pdf]
model.input_cost        #=> 2 (USD per million tokens)

{:ok, models} = Omni.list_models(:anthropic)
```

`Omni.Model` describes every field.

### Adding and correcting models

When a model is missing from the catalog, such as a new release or a fine-tune, add it under its provider. A new model names its dialect, because there is no catalog data to take it from:

```elixir
config :omni, :providers,
  openai: [models: [
    [id: "ft:gpt-4o:acme::abc123", dialects: %{text: Omni.Dialects.OpenAIResponses}]
  ]]
```

An entry whose id the catalog already has is merged over the catalog's model, so you can correct one field and leave the rest:

```elixir
config :omni, :providers,
  anthropic: [models: [
    [id: "claude-sonnet-5-5", max_output_tokens: 200_000]
  ]]
```

A local Ollama has no catalog at all: its models are whatever you have pulled. List them by id:

```elixir
config :omni, :providers, ollama: [models: ["llama3.1:8b", "qwen3.5:4b"]]
```

## Where model data comes from

Model data comes from a **source**. The default reads a snapshot of the models.dev catalog that ships inside Omni, so startup needs no network. Each Omni release carries a fresh snapshot.

For newer data than the last release, fetch the catalog at startup. The result is cached on disk, and if models.dev can't be reached Omni falls back to the cache and then to the bundled snapshot:

```elixir
config :omni, :models, source: {Omni.Sources.ModelsDev, live: true}
```

Or read the catalog from the [`llm_db`](https://hex.pm/packages/llm_db) package, which you add to your own deps:

```elixir
config :omni, :models, source: Omni.Sources.LLMDB
```

Changing the source doesn't change provider ids: every source is asked for a provider by the same id, and matches it to its own catalog. What can change is which providers and models it knows. A provider the source has no data for is treated as a custom provider, so it needs its endpoints and models in config.

A source can be set for one provider with `:source` in its config. To write a source of your own, see `Omni.Source`.

Sources load the models Omni can use: text models that support tool use, and decision models. Embedding, image and speech models are left out, as are deprecated models.

## Filtering and transforming models

Two more keys under `config :omni, :models` work on every model as it loads. Both take a `{Module, :function}` pair.

`filter:` decides which models are kept. The function gets each model and returns true to keep it:

```elixir
config :omni, :models, filter: {MyApp.Models, :keep?}

defmodule MyApp.Models do
  # Text models released since the start of 2026
  def keep?(%Omni.Model{release_date: date} = model) do
    Omni.Model.capability?(model, :text) and date != nil and Date.compare(date, ~D[2026-01-01]) != :lt
  end
end
```

`transform:` changes models. The function gets each model and returns it, changed or as it was. It runs before the filter, and can change any field except the model's `id` and `provider`:

```elixir
config :omni, :models, transform: {MyApp.Models, :transform}

defmodule MyApp.Models do
  # We have a negotiated rate with this provider
  def transform(%Omni.Model{provider: %{id: :deepseek}} = model) do
    %{model | input_cost: model.input_cost * 0.8, output_cost: model.output_cost * 0.8}
  end

  def transform(model), do: model
end
```

Use a provider's `models:` to correct one model by id, and `transform:` to change many by pattern.

### Moving models to another dialect

Many providers serve the same models over more than one API. Groq, for example, serves Chat Completions and OpenAI's Responses API. The catalog gives each model one dialect, and you may want another.

> #### You are on your own here {: .warning}
>
> Omni's built-in providers are set up and checked for the dialect the catalog gives them. A dialect you move models to starts with no compat flags, and finding the ones it needs is up to you. Check the result with `mix omni.verify`.

It takes two steps. First declare the endpoint for the new dialect on the provider:

```elixir
config :omni, :providers,
  groq: [dialects: %{
    Omni.Dialects.OpenAIResponses => [
      base_url: "https://api.groq.com/openai/v1"
    ]
  }]
```

Then move the models to it in a transform:

```elixir
config :omni, :models, transform: {MyApp.Models, :transform}

defmodule MyApp.Models do
  alias Omni.Dialects.{OpenAICompletions, OpenAIResponses}

  def transform(%Omni.Model{provider: %{id: :groq}, dialects: %{text: OpenAICompletions}} = model) do
    put_in(model.dialects.text, OpenAIResponses)
  end

  def transform(model), do: model
end
```

Matching on the model's current dialect matters for gateways, where not every model is served on every API. A transform that leaves a model on a dialect its provider has no endpoint for raises at startup.

## Checking a model works

`mix omni.verify` runs a handful of real requests against one model, using your config, and reports which pass:

```sh
mix omni.verify deepseek:deepseek-v4-pro
```

It covers text, thinking, tool use and structured output by default, or the two decision scenarios for a decision model, with more on request (images, PDFs, caching, a multi-turn tool loop). The requests are real and billed to your key. Run it when you add a catalog or custom provider, change compat flags, or move models to another dialect. `mix help omni.verify` has the options.

## Going further

- **Loading at runtime.** `Omni.Provider.load/1` loads providers after startup, and `Omni.put_model/1` registers a single model. Both are for apps that learn about providers and models while running.
- **Provider modules.** When a provider needs something flags can't describe, such as a quirk only some of its models have, a module can adjust its models and its request bodies. `Omni.Provider` documents the callbacks.
- **Writing a dialect.** An API that speaks none of Omni's dialects needs one of its own. `Omni.Dialect` is the place to start.
