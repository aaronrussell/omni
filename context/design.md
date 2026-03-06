# Omni Design Document

**Status:** Ready for implementation -- reviewed and refined
**Last updated:** February 2026

---

## Overview

Omni is an Elixir library for interacting with LLM APIs across multiple providers. The core challenge is managing a large, ever-changing catalog of models across many providers, where providers share a small number of underlying API formats but each has its own configuration, authentication, and quirks.

The design separates three distinct concerns:

- **Models** -- data describing a specific LLM (capabilities, pricing, limits)
- **Providers** -- the identity and configuration of a specific service (Anthropic, OpenAI, Groq, etc.)
- **Dialects** -- the wire format for a family of APIs (how requests are built and responses are parsed)

The relationship: there are ~5 dialects, ~20-30 providers (most speaking one dialect, though multi-model gateways like OpenCode Zen use multiple), and hundreds of models (each belonging to one provider). The dialect is stored on each `%Model{}` struct, so dispatch is always per-model.

---

## Top-Level API

### Core functions

```elixir
Omni.generate_text(model, context, opts \\ [])  # -> {:ok, %Response{}} | {:error, reason}
Omni.stream_text(model, context, opts \\ [])     # -> {:ok, %StreamingResponse{}} | {:error, reason}
```

Both functions return `{:ok, result} | {:error, reason}` because errors can occur before the request starts (model not found, invalid context/options, auth failures, bad status codes). These surface immediately at the call site rather than falling out mid-stream.

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

The `model` parameter accepts multiple formats:

- **Model struct** -- if the caller has already looked up the model
- **Provider/model tuple** -- `{:anthropic, "claude-sonnet-4-20250514"}`

Bare string model IDs are not supported to avoid ambiguity when the same model ID appears on multiple providers.

```elixir
# With a tuple (most common)
Omni.generate_text({:anthropic, "claude-sonnet-4-20250514"}, context)

# With a pre-fetched struct
model = Omni.get_model(:anthropic, "claude-sonnet-4-20250514")
Omni.generate_text(model, context)
```

### Context argument

The `context` parameter accepts multiple formats, coerced internally via a `to_context` helper:

- **String** -- treated as a single user message
- **Message list** -- a conversation with no system prompt or tools
- **Context struct** -- the full representation with system prompt, messages, and tools

```elixir
# Simple prompt string
Omni.generate_text(model, "What is the capital of France?")

# List of messages
Omni.generate_text(model, [
  %Omni.Message{role: :user, content: "Hello"},
  %Omni.Message{role: :assistant, content: "Hi there!"},
  %Omni.Message{role: :user, content: "What's the weather?"}
])

# Full context
Omni.generate_text(model, %Omni.Context{
  system: "You are a weather assistant",
  messages: messages,
  tools: [weather_tool]
})
```

The `to_context` helper normalises all formats into an `Omni.Context` struct:

```elixir
defp to_context(%Omni.Context{} = context), do: context
defp to_context(messages) when is_list(messages), do: %Omni.Context{messages: messages}
defp to_context(prompt) when is_binary(prompt) do
  %Omni.Context{messages: [%Omni.Message{role: :user, content: prompt}]}
end
```

The `Omni.Context` struct represents the "what" -- everything the model needs to know:

```elixir
%Omni.Context{
  system: "string",       # optional system prompt
  messages: [message],    # conversation history
  tools: [tool]           # available tools
}
```

The litmus test for what belongs in context vs options: **context is "what the model knows", options are "how to behave"**. This is why `tool_choice` is an option (it's a behavioural directive) even though `tools` is in context.

### Options argument

Options are a flat keyword list mixing inference options, provider-specific options, and request options. The caller doesn't need to categorise them -- the internal orchestration routes each option to the right layer.

```elixir
Omni.generate_text(model, context,
  # Inference options (unified, handled by dialect)
  max_tokens: 4096,
  temperature: 0.7,

  # Provider-specific options (passed through to dialect/provider)
  thinking: :high,
  tool_choice: :auto,
  cache: :short,

  # Request options (handled by provider/auth layer)
  api_key: "sk-ant-...",
  base_url: "https://custom-proxy.com",
  headers: %{"x-custom" => "value"},

  # Debug options
  raw: true   # include raw Req request/response on the Response struct
)
```

The unified inference options are deliberately minimal -- only the options users regularly tune:

- `max_tokens`
- `temperature`
- `top_p`
- `stop` (stop sequences)

Provider-specific options (like `thinking`, `tool_choice`, `effort`) are passed through without transformation. Each dialect/provider declares which options it supports via an `option_schema/0` callback, enabling helpful validation error messages. Option validation is handled using the Peri library for schema-based validation.

API keys and other request config are resolved in priority order:

1. **Call-time opts** -- passed directly in the options keyword list
2. **Application config** -- set in `config.exs`
3. **Provider default** -- the fallback defined in the provider's config

This means models stay as pure data -- they never carry runtime config like API keys.

### Caching

The `cache` option controls explicit prompt caching hints. It does not enable or disable caching -- some providers (OpenAI, Gemini) cache implicitly by default regardless of this option. The option tells Omni to add explicit caching directives to the request where the provider supports them.

```elixir
Omni.generate_text(model, context, cache: :short)
```

The accepted values are:

- **`nil`** (default) -- no explicit caching directives. Providers with implicit caching (OpenAI, Gemini) may still cache.
- **`:short`** -- explicit caching with a short TTL (typically 5 minutes).
- **`:long`** -- explicit caching with an extended TTL (typically 1 hour).

Each dialect translates the option into the appropriate provider mechanism:

| Option | Anthropic | OpenAI Responses | OpenAI Completions | Gemini |
|--------|-----------|------------------|--------------------|--------|
| `nil` | No breakpoints | No retention hint | No-op (implicit) | No TTL hint |
| `:short` | Breakpoints, 5min TTL | Short retention | No-op (implicit) | Short TTL |
| `:long` | Breakpoints, 1hr TTL | Extended retention | No-op (implicit) | Extended TTL |

For Anthropic, the dialect places `cache_control` breakpoints on the system prompt and last message content block. The provider's prefix matching handles the rest -- previous messages that match the cached prefix get cache hits automatically, even as new messages are appended. For providers without explicit caching support, the option is silently ignored (caching is an optimisation hint, not a semantic requirement).

---

## Models

### What a model is

A model is a data struct -- not a module. It describes a specific LLM's identity, capabilities, and pricing. Models are loaded from data files, not defined in code.

```elixir
defmodule Omni.Model do
  defstruct [
    :id,             # Provider's model ID string, eg "claude-sonnet-4-20250514"
    :name,           # Human-readable name, eg "Claude Sonnet 4"
    :provider,       # Provider module, eg Omni.Providers.Anthropic
    :dialect,        # Dialect module, eg Omni.Dialects.AnthropicMessages
    modalities: %{
      input: [:text],
      output: [:text]
    },
    reasoning: false,
    cost: %{
      input: 0,      # $/million tokens
      output: 0,
      cache_read: 0,
      cache_write: 0
    },
    context_window: 0,
    max_output_tokens: 0
  ]
end
```

The `provider` and `dialect` fields store full module references, not shorthand atoms. This means a resolved model is self-contained -- it can be used to call provider and dialect callbacks directly without any runtime module resolution step. The shorthand atom (`:anthropic`) exists only as a human-friendly key for lookups and config, declared in the application config when registering providers.

### Where model data lives

Model data is stored as JSON files in `priv/models/`, one file per provider:

```
priv/models/anthropic.json
priv/models/openai.json
priv/models/groq.json
```

Each file contains an array of model objects. Provider-level concerns (base URL, dialect, auth) are **not** stored in the JSON -- only model-specific data:

```json
[
  {
    "id": "claude-sonnet-4-20250514",
    "name": "Claude Sonnet 4",
    "reasoning": false,
    "input_modalities": ["text", "image"],
    "output_modalities": ["text"],
    "cost": {
      "input": 3.0,
      "output": 15.0,
      "cache_read": 0.3,
      "cache_write": 3.75
    },
    "context_window": 200000,
    "max_output_tokens": 8192
  }
]
```

These files are populated by a mix task that fetches data from [models.dev](https://models.dev/) and transforms it into Omni's format. The files are committed to the repository and ship with the library -- consumers get a known-good snapshot without needing network access at runtime.

Users can also manually edit these files to add newly released models before Omni updates.

### How model data is loaded

On application startup, `Omni.Application` iterates the configured provider modules and calls each provider's `models/0` callback to get its model list. Each model list is stored into `:persistent_term` -- a global key-value store built into the BEAM VM. This is not a process; it requires no supervision tree entry. It is optimised for data that is written rarely and read frequently, where reads are essentially free (no message passing, no data copying).

Models are stored per-provider as separate persistent_term entries, keyed by the provider's shorthand id:

```elixir
:persistent_term.put({Omni, :anthropic}, %{
  "claude-sonnet-4-20250514" => %Omni.Model{
    provider: Omni.Providers.Anthropic,
    dialect: Omni.Dialects.AnthropicMessages,
    ...
  },
  "claude-opus-4-20250514" => %Omni.Model{...}
})

:persistent_term.put({Omni, :openai}, %{...})
```

The startup loading logic is uniform for every provider -- built-in or custom:

```elixir
defmodule Omni.Application do
  use Application

  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    providers = Application.get_env(:omni, :providers, @default_providers)

    for {provider_id, provider_mod} <- Enum.map(providers, &normalize_provider/1) do
      model_map = Map.new(provider_mod.models(), &{&1.id, &1})
      :persistent_term.put({Omni, provider_id}, model_map)
    end
  end

  defp normalize_provider({_id, _mod} = pair), do: pair
  defp normalize_provider(id) when is_atom(id) do
    module = Module.concat(Omni.Providers, id |> to_string() |> Macro.camelize())

    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
        "unknown built-in provider #{inspect(id)} - module #{inspect(module)} does not exist"
    end

    {id, module}
  end
end
```

Which providers are loaded is controlled by application config. Built-in providers are referenced by shorthand atom; custom providers use a `{id, module}` tuple:

```elixir
config :omni, :providers, [
  :anthropic,
  :openai,
  :groq,
  custom: MyApp.Providers.Custom
]
```

The shorthand atom `:anthropic` is normalised to `{:anthropic, Omni.Providers.Anthropic}` at startup. The `{id, module}` tuple form allows custom providers to be registered under any id. Provider IDs are defined only in the config -- provider modules do not declare their own IDs, eliminating the possibility of ID conflicts between modules.

If no providers are configured, a sensible default set is loaded (Anthropic, OpenAI, etc.), so the library works out of the box without requiring any config.

The empty supervisor returned by `start/2` is just the OTP contract -- `start/2` must return `{:ok, pid}`. The real work is the `load_providers` call, which is synchronous and fast (reading a handful of JSON files from disk). This guarantees models are available by the time any user code runs.

### Why not an Agent or GenServer for storage?

An Agent serialises all access through a single process mailbox. For a read-heavy lookup table (written once at startup, queried from many concurrent processes), this creates an unnecessary bottleneck. `:persistent_term` gives concurrent reads from any process with zero overhead.

### Model lookup

Model lookup functions live on the top-level `Omni` module. The `get_model/2` function takes a provider shorthand atom and model ID string, performing a direct `:persistent_term` lookup:

```elixir
def get_model(provider_id, model_id) do
  case :persistent_term.get({Omni, provider_id}, nil) do
    nil -> {:error, {:unknown_provider, provider_id}}
    models ->
      case Map.get(models, model_id) do
        nil -> {:error, {:unknown_model, provider_id, model_id}}
        model -> {:ok, model}
      end
  end
end
```

The returned `%Model{}` struct has direct module references for both `provider` and `dialect`, so no further resolution is needed before making requests.

---

## Providers

### What a provider is

A provider is a module implementing a behaviour. It represents a specific LLM service -- its endpoint, authentication mechanism, and any service-specific adaptations. A provider is the authenticated HTTP layer -- it knows *where* to send requests and *how* to authenticate them, but not *what* the request body should contain (that's the dialect's job).

Most providers are largely declarative configuration. The provider can be used independently to make authenticated HTTP requests with a provider-native request body, without involving a dialect at all.

### The role of a provider

A provider answers the question: **"How do I reach and authenticate with this specific service?"**

It's operational identity. A provider knows where it lives (base URL), how to prove you're allowed to talk to it (authentication), and any service-specific adjustments on top of the standard dialect. The provider has no knowledge of request body structure or response parsing -- it doesn't know what JSON fields exist or how streaming events are shaped.

The separation from dialects exists because the mapping is typically many-to-one. There are ~4-5 wire formats but ~20-30 services. Groq, Together, Fireworks, OpenRouter, DeepSeek, and a dozen others all speak the same OpenAI Chat Completions wire format. Their request bodies are identical. Their streaming events have the same JSON schema. The only things that differ are: where you send the request, how you authenticate, and maybe a handful of quirks.

Some providers are multi-dialect gateways -- they route to different upstream APIs depending on the model. OpenCode Zen, for example, serves Claude models via the Anthropic Messages format and GPT models via OpenAI Responses, all through a single service. These providers omit the `:dialect` option from `use Omni.Provider`, and each model gets its dialect from the JSON data file instead.

### The Omni.Provider module

`Omni.Provider` serves as both the behaviour definition and the home for shared utilities. This includes:

- The provider behaviour and `__using__` macro with default implementations
- Model data loading logic (`load_models/2` -- reading JSON, building model structs)
- Auth resolution (`resolve_auth/1` -- literal, `{:system, env}`, MFA, nil)
- Provider loading (`load/1` -- loads providers' models into `:persistent_term`)

Request building and event parsing orchestration lives in `Omni.Request`, not on Provider. The Provider module defines callbacks; `Omni.Request` composes them. `Omni.stream_text/3` is a thin wrapper that delegates to `Request.build/3` and `Request.stream/3`.

### Provider declaration

Each provider module uses `use Omni.Provider`, typically with a dialect:

```elixir
defmodule Omni.Providers.Anthropic do
  use Omni.Provider, dialect: Omni.Dialects.AnthropicMessages
end
```

The `use` macro generates a `dialect/0` accessor function from the provided value (or `nil` when omitted). Most providers declare a single dialect. Multi-dialect providers omit the option -- `dialect/0` returns `nil`, and each model's dialect is resolved from the JSON data file at load time via `Omni.Dialect.get!/1`. Provider IDs are not declared on the module; they are assigned in the application config when registering providers.

### Provider behaviour callbacks

The provider behaviour defines the following callbacks:

| Callback | Returns | Default | Purpose |
|----------|---------|---------|---------|
| `config/0` | `map()` | *required* | Base URL, auth header name, auth default value, headers |
| `models/0` | `[%Model{}]` | `[]` | Returns the provider's model list |
| `build_url/2` | `String.t()` | Concatenation | Builds full URL from path and merged config map |
| `authenticate/2` | `{:ok, Req.Request.t()} \| {:error, reason}` | API key header | Adds auth to a Req request |
| `modify_body/3` | `map()` | Passthrough | Modifies the dialect-built request body (receives body, context, opts) |
| `modify_events/2` | `[{atom(), map()}]` | Passthrough | Modifies dialect-parsed deltas (post-dialect, receives raw event for context) |

**Which callbacks can fail:** Only `authenticate/2` returns an ok/error tuple, because authentication involves real external dependencies that can fail at runtime (missing environment variables, unreachable vaults, expired tokens). All other callbacks either return static data or perform deterministic transformations on already-validated inputs.

### Provider config

Each provider defines a `config/0` function returning a map of structural and default configuration:

```elixir
defmodule Omni.Providers.Anthropic do
  use Omni.Provider, dialect: Omni.Dialects.AnthropicMessages

  @impl true
  def config do
    %{
      base_url: "https://api.anthropic.com",
      auth_header: "x-api-key",
      auth_default: {:system, "ANTHROPIC_API_KEY"}
    }
  end
end
```

This is a plain function returning a map -- no macros or DSL. This keeps the code immediately understandable, testable, and allows dynamic config when needed. Note that the dialect is declared in `use Omni.Provider`, not in `config/0` -- a provider's dialect is truly static identity, while `config/0` holds operational values.

### Provider models

Each provider has a `models/0` callback that returns its list of `%Model{}` structs. The default implementation returns an empty list -- providers that have models must explicitly implement the callback.

Built-in providers use the `Omni.Provider.load_models/2` helper, which reads a JSON data file and builds model structs stamped with the provider module and a dialect:

```elixir
defmodule Omni.Providers.Anthropic do
  use Omni.Provider, dialect: Omni.Dialects.AnthropicMessages

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/anthropic.json")
  end
end
```

`load_models/2` takes the provider module and a file path. It resolves the dialect in priority order: if `module.dialect()` returns a module, that dialect is used for all models; otherwise, each model's `"dialect"` string from the JSON data is resolved via `Omni.Dialect.get!/1`. The models returned from `models/0` are always complete -- all enforce_keys are populated.

Custom providers can implement `models/0` to return models from any source:

```elixir
defmodule MyApp.Providers.Internal do
  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def models do
    [
      %Model{
        id: "our-fine-tuned-model",
        name: "Our Fine-tuned Model",
        provider: __MODULE__,
        dialect: dialect(),
        context_size: 128_000,
        max_output_tokens: 4096
      }
    ]
  end
end
```

This can also be dynamic -- a provider that fetches its model list from an internal API, for example.

### Authentication

Auth is handled by the `authenticate/2` callback, which receives a Req request and the resolved config, and returns a modified request with authentication applied. This is necessary because auth mechanisms vary significantly across providers:

- Most providers: a single API key in a header (Bearer token or custom header)
- AWS Bedrock: SigV4 request signing (multiple headers computed from request body)
- Azure OpenAI: API key header or Azure AD bearer tokens with refresh flows
- Google Vertex AI: short-lived tokens from service account credentials

`use Omni.Provider` provides a default implementation that resolves an API key and sends a Bearer token on the `"authorization"` header. When a provider sets a custom `:auth_header` in `config/0` (e.g. `"x-api-key"`), the raw key is sent on that header instead. This covers the majority of providers without overrides. Providers with exotic auth (like Bedrock) override the callback entirely.

### API key resolution

API keys can be provided in multiple ways, resolved in priority order:

1. **Call-time opts** -- passed directly when making a request (for multi-tenant apps)
2. **Application config** -- set per-provider in `config.exs` (e.g. `config :omni, Omni.Providers.Anthropic, api_key: "..."`)
3. **Provider default** -- the fallback defined in the provider's `config/0`

Supported value formats:

- `"sk-ant-..."` -- a literal string
- `{:system, "ENV_VAR_NAME"}` -- an environment variable
- `{Module, :function, [args]}` -- an MFA tuple for dynamic resolution (vault, secrets manager)

### Provider config overrides

Deployment-specific values like `base_url` and `api_key` can be overridden via application config without modifying the provider module. Per-provider config uses the provider module as the config key, separate from provider registration:

```elixir
# Provider registration (which providers to load)
config :omni, :providers, [:anthropic, :openai]

# Per-provider config overrides (deployment-specific values)
config :omni, Omni.Providers.OpenAI,
  api_key: {:system, "AZURE_OPENAI_KEY"},
  base_url: "https://my-instance.openai.azure.com"
```

This separates two concerns: the `:providers` key controls which providers are registered at startup, while per-module config keys control runtime behaviour. The provider module defines the **structural contract** (header name, dialect, URL path structure) and **sensible defaults** in `config/0`. Application config overrides deployment-specific values. The framework merges per-module config into the provider's defaults at call time.

### URL building

The `build_url/2` callback constructs the full URL from the dialect-built path and the unified opts map. The default implementation concatenates `opts.base_url` with the path:

```elixir
def build_url(path, opts) do
  opts.base_url <> path
end
```

The opts map contains `base_url` (from three-tier merge), `api_key`, `auth_header`, `headers`, plus all inference options. Providers that restructure URLs (e.g. Azure OpenAI, which reorganises the path around deployment names and API versions) override this callback and pull what they need from the map.

### Provider modifications

Some providers speak a standard dialect but with minor deviations -- an extra required field, a parameter that needs renaming, additional data in streaming events. Two optional callbacks handle this:

- **`modify_body/3`** -- receives the dialect-built request body, the original `%Context{}`, and the validated options map. The context parameter enables provider-specific per-message transformations (e.g. OpenRouter encoding `reasoning_details` from `Message.private` onto wire-format assistant messages). Returns the modified body. Default is passthrough.
- **`modify_events/2`** -- receives the dialect-parsed delta list and the original raw SSE event map. The provider can modify, remove, or add deltas. Returns the modified delta list. Default is passthrough.

These are *modifications* of the dialect's standard output, not alternatives to it. The dialect does the real transformation; the provider makes small, targeted adjustments. Most providers don't need either callback.

**`modify_events/2` runs post-dialect.** The dialect parses the raw SSE event first (`handle_event/1`), then the provider can augment the parsed deltas with provider-specific data. This mirrors the request side where the dialect builds first (`handle_body/3`), then the provider modifies (`modify_body/3`). The raw event is passed as the second argument so the provider can inspect it for data the dialect doesn't know about (e.g. OpenRouter's `reasoning_details`).

### Orchestration lives in Omni.Request

Request building and event parsing orchestration lives in `Omni.Request`, not on the Provider module or as private functions in `Omni`. The Provider module defines callbacks; `Omni.Request` composes them. This keeps the Provider as a pure behaviour + utilities module while enabling granular unit testing of request building, validation, and event parsing.

`Omni.Request` has two public functions (`build/3`, `stream/3`) and two `@doc false` functions exposed for testing (`validate/2`, `parse_event/2`). `Omni.stream_text/3` is a thin wrapper that delegates to these.

The orchestration calls provider and dialect callbacks directly via the module references on the `%Model{}` struct:

```elixir
body = model.dialect.handle_body(model, context, opts)
body = model.provider.modify_body(body, context, opts)
path = model.dialect.handle_path(model, opts)
url = model.provider.build_url(path, opts)
```

Each layer is independently testable: dialect callbacks are pure functions (maps in, maps out), provider callbacks are small targeted modifications, and the full pipeline is tested via `stream_text` with Req.Test stubs.

### Custom providers

Users implement custom provider modules using the same behaviour:

```elixir
defmodule MyApp.Providers.Internal do
  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://internal-llm.company.com",
      api_key: {:system, "INTERNAL_LLM_KEY"}
    }
  end

  @impl true
  def models do
    [
      %Model{
        id: "our-model",
        name: "Our Model",
        provider: __MODULE__,
        dialect: dialect(),
        context_size: 128_000,
        max_output_tokens: 4096
      }
    ]
  end
end
```

Custom providers are registered in the application config using a `{id, module}` tuple:

```elixir
config :omni, :providers, [
  :anthropic,
  :openai,
  internal: MyApp.Providers.Internal
]
```

Users can also construct `%Model{}` structs directly and pass them to `stream_text/3` without registering the provider -- the model struct carries direct module references, so `stream_text` can call provider and dialect callbacks directly without touching `:persistent_term`.

---

## Dialects

### What a dialect is

A dialect is a module implementing a behaviour. It defines the wire format for a family of APIs -- how to build request bodies, construct URL paths, and parse streaming events. A dialect is pure data transformation with no knowledge of HTTP, configuration, or specific providers.

### The role of a dialect

A dialect answers the question: **"What does this API family expect to receive, and what does it send back?"**

Given Omni's internal types (Context, Messages, Content blocks, Tools, options), a dialect knows how to reshape them into the JSON structure a particular API family expects. And given streaming events coming back, it knows how to interpret them as Omni's normalised deltas. A dialect has no concept of "where" the API lives or "who" is calling it. It's a bidirectional translator between Omni's world and a wire format.

The separation from providers exists because many providers share the same wire format. The OpenAI Chat Completions dialect is written and tested once, and each provider that speaks it (Groq, Together, Fireworks, OpenRouter, etc.) is just a small module of config + auth.

### Expected dialects

There are approximately 4-5 dialects:

- **OpenAI Chat Completions** -- used by OpenAI and the majority of third-party providers (Groq, Together, Fireworks, OpenRouter, etc.)
- **Anthropic Messages** -- used by Anthropic (and Bedrock, which uses the same message format with different auth/transport)
- **Google Gemini** -- Google's native API format
- **OpenAI Responses** -- OpenAI's newer response format (if needed)
- Possibly others as the ecosystem evolves

### Dialect behaviour callbacks

The dialect behaviour defines the following callbacks:

| Callback | Returns | Purpose |
|----------|---------|---------|
| `option_schema/0` | `map()` | Peri schema declaring which inference/dialect options are accepted |
| `handle_path/2` | `String.t()` | Returns the URL path for the given model and opts |
| `handle_body/3` | `map()` | Builds the request body from model, context, and validated options |
| `handle_event/1` | `[{atom(), map()}]` | Parses a decoded SSE event map into a list of delta tuples |

**No callback returns ok/error tuples.** Option validation happens at the API boundary (`stream_text`) before any dialect callbacks are called. Dialects receive validated options and operate on known-good data. `handle_body/3` returns a bare map. `handle_event/1` returns a list of delta tuples (empty list to skip). `option_schema/0` and `handle_path/2` return static data.

### Dialect callback details

**`option_schema/0`** -- returns a Peri schema map declaring which options this dialect understands. The orchestration layer merges this with the universal option schema, then validates the full options in a single pass before any work begins. Result is a map with defaults filled in.

**`handle_path/2`** -- receives a `%Model{}` struct and opts, returns the URL path string. This is typically a static path with the model ID interpolated for some API families:

```elixir
# Anthropic Messages dialect
def handle_path(_model, _opts), do: "/v1/messages"

# OpenAI Completions dialect
def handle_path(_model, _opts), do: "/v1/chat/completions"
```

**`handle_body/3`** -- receives a `%Model{}`, `%Context{}`, and validated options map. Returns a body map. This is where Omni's types become the provider's native JSON structure -- messages are reshaped, content blocks are encoded, tools are serialized, and options are mapped to API parameters. Options have already been validated and include defaults, so there is no need for fallback values.

```elixir
# Simplified example
def handle_body(model, context, opts) do
  %{
    "model" => model.id,
    "messages" => encode_messages(context.messages),
    "system" => context.system,
    "max_tokens" => opts.max_tokens,
    "temperature" => opts[:temperature],
    "stream" => true
  }
end
```

**`handle_event/1`** -- receives a single decoded JSON event map (from the SSE parser) and returns a list of normalised `{event_type, event_map}` delta tuples. Returns an empty list `[]` to skip the event. The function is stateless and pure -- it receives one event, returns deltas. No accumulation, no knowledge of what came before. This makes dialects trivially testable: give it a JSON map, assert the tuples that come out.

```elixir
# Anthropic dialect example
def handle_event(%{"type" => "content_block_delta", "index" => idx,
                   "delta" => %{"type" => "text_delta", "text" => text}}) do
  [{:block_delta, %{type: :text, index: idx, delta: text}}]
end

def handle_event(%{"type" => "message_delta",
                   "delta" => %{"stop_reason" => reason}, "usage" => usage}) do
  [{:message, %{stop_reason: normalise_stop_reason(reason), usage: usage}}]
end
```

### Option validation

Options are validated once, early, in `stream_text` before any callbacks are called. The validation schema is composed from two sources:

1. **Universal schema** -- defined as a module attribute in `Omni`. Covers standard inference options: `max_tokens`, `temperature`, `cache`, `metadata`, `thinking`.
2. **Dialect schema** -- from `dialect.option_schema/0`. Covers dialect-specific options.

These are merged into one Peri schema and validated in a single pass using strict mode (unknown keys are rejected, catching typos). The result is a map with all defaults filled in. All downstream callbacks receive this validated map.

Request config options (`api_key`, `base_url`, `headers`, `plug`, `raw`) are separated out before validation -- they are transport/framework concerns, not inference options.

Dialect output (the request body) is not validated at runtime. If a dialect produces malformed output, that's a bug in the library caught by tests, not a runtime concern.

### Relationship to providers

Many providers share a dialect. For example, Groq, Together, Fireworks, and OpenRouter all use the OpenAI Chat Completions dialect. The provider references its dialect via `use Omni.Provider`, and the orchestration layer calls the dialect for data transformation and the provider for configuration and auth.

### Testability

Each layer is testable independently:

```elixir
# Test a dialect in pure isolation -- no HTTP, no provider
body = AnthropicMessages.handle_body(model, context, opts)
assert body["messages"] == [...]

deltas = AnthropicMessages.handle_event(%{"type" => "content_block_delta", ...})
assert deltas == [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}]

# Test a provider's modifications in isolation
modified = OpenRouter.modify_body(body, context, opts)
assert modified["reasoning"] == %{"effort" => "high"}

# Test the full stack
{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-20250514"}, "Hi")
```

The dialect is pure functions (maps in, maps out). The provider makes small targeted modifications. The top-level API composes them.

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
    timestamp: nil    # DateTime, local metadata -- not from the API
  ]

  def new(attrs) do
    struct!(__MODULE__, Map.put_new_lazy(attrs, :timestamp, &now/0))
  end

  defp now, do: DateTime.utc_now()
end
```

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
    %Content.ToolResult{tool_use_id: "call_123", content: "15C, cloudy"}
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
    :stop_reason,   # :stop | :length | :tool_use | :error
    :error,         # nil | {:stream_error, String.t()}
    :raw            # nil | {%Req.Request{}, %Req.Response{}}
  ]
end
```

**Composition over flattening:** Because the response contains a fully-formed `%Message{}`, appending to a conversation thread is straightforward:

```elixir
response = Omni.generate_text(model, context)

# Extract the message and append to the context
context = Context.append(context, response.message)

# Context.append/2 could also accept a Response directly and extract .message
context = Context.append(context, response)
```

No conversion step is needed -- the message was never disassembled.

**Stop reason is response metadata, not conversation data.** The stop reason doesn't need to be carried in the message sequence. If the model stopped because of a tool use, there will be a tool use content block in the message's content list -- that block is what tells the conversation "this turn used a tool", and it's what dialects look at when building the next request. The stop reason is metadata *about* the generation event, redundant with the content blocks for conversation purposes.

### Raw request/response access

The raw Req request and response are available for debugging by passing `raw: true` in options:

```elixir
{:ok, response} = Omni.generate_text(model, context, raw: true)
{req, res} = response.raw
```

The `raw` field is `nil` by default and populated with `{%Req.Request{}, %Req.Response{}}` when requested. The raw Req structs are stored directly -- the point of the escape hatch is access to what actually happened on the wire, not another abstraction layer over it.

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

The `Usage` module provides an `add/2` function for summing usage across multiple requests -- useful for tracking spend in agentic loops or building usage dashboards:

```elixir
total_usage = Enum.reduce(responses, %Usage{}, fn response, acc ->
  Usage.add(acc, response.usage)
end)
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
    :input_schema,   # JSON Schema map describing expected input
    :handler         # nil | (map -> any) -- local metadata, ignored by dialects
  ]
end
```

The `input_schema` field holds a JSON Schema map -- the universal wire format every provider accepts. The name `input_schema` is used over `parameters` for consistency with `ToolUse.input` (the tool defines its `input_schema`, the model returns `input` conforming to that schema) and to avoid OpenAI's baggage where parameters was nested under a `function` wrapper.

The `handler` field is local metadata, like `timestamp` on messages -- it exists for the user's convenience and is ignored by dialects when serializing tool definitions. If present, it's a single-arity function `(map -> any)` that executes the tool given the model's input.

### Schema helpers

Raw JSON Schema is verbose and error-prone. `Omni.Schema` provides plain builder functions that return standard JSON Schema maps:

```elixir
defmodule Omni.Schema do
  def object(properties, opts \\ [])
  def string(opts \\ [])
  def number(opts \\ [])
  def integer(opts \\ [])
  def boolean(opts \\ [])
  def array(items, opts \\ [])
  def enum(values, opts \\ [])
  def any_of(schemas, opts \\ [])
  def update(schema, opts)
  def validate(schema, input)
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

`validate/2` converts the schema to a Peri validation schema internally. It enforces types, required fields, string constraints (`minLength`, `maxLength`, `pattern`), numeric constraints (`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`), and `anyOf` unions. Array item types are validated, but array-level constraints (`minItems`, `maxItems`, `uniqueItems`) and `multipleOf` are not -- these are sent to the LLM in the schema but skipped during local validation.

These are plain functions returning maps -- no macros, no special types, no compilation step. Developers who already have JSON Schema maps (from OpenAPI specs, existing code) pass them directly. The dialect doesn't know or care which path produced the map.

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

For reusable, self-contained tools, the `Omni.Tool` behaviour and `use Omni.Tool` macro provide a module-based pattern. Name and description are passed as arguments to `use` (they're static configuration, not behaviour), while `schema/0`, `init/1`, and `call/1,2` are callbacks:

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

The `use` macro generates `name/0` and `description/0` functions from the provided values (available for introspection but not hand-written), and generates `new/0` and `new/1` constructors that produce a `%Tool{}` struct:

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
    description: description(),
    input_schema: schema(),
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

### Tool execution

`Omni.Tool.execute/2` validates input against the tool's schema and dispatches to the handler:

```elixir
{:ok, result} = Omni.Tool.execute(tool, tool_use.input)
```

If the tool has an `input_schema`, the LLM's string-keyed input is validated via `Omni.Schema.validate/2` and cast to match the schema's key types -- handlers receive atom keys when the schema uses atoms. Returns `{:ok, result}` on success, `{:error, errors}` on validation failure. Direct handler calls (`tool.handler.(input)`) bypass validation.

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
  defstruct [:text, :signature]
end
```

Represents a model's reasoning/thinking output. The `signature` field is used by Anthropic to verify thinking block authenticity when they're passed back in multi-turn conversations. When `text` is `nil`, the thinking content has been redacted by the provider -- no separate `redacted` flag is needed since it's directly derivable from the nil text.

### Attachment

```elixir
defmodule Omni.Content.Attachment do
  defstruct [:source, :media_type, :description, opts: %{}]
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

The `description` field provides alt text or a description of the content. The `opts` map holds provider-specific options (e.g. OpenAI's image `detail` parameter) without polluting the struct with fields that only apply to one provider.

```elixir
# Image with URL
%Attachment{
  source: {:url, "https://example.com/chart.png"},
  media_type: "image/png",
  description: "Q3 revenue chart"
}

# PDF from base64
%Attachment{
  source: {:base64, pdf_data},
  media_type: "application/pdf"
}

# Image with provider-specific options
%Attachment{
  source: {:base64, image_data},
  media_type: "image/jpeg",
  opts: %{detail: "high"}
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
  defstruct [:tool_use_id, :content, is_error: false]
end
```

Represents the result of a tool use, sent back to the model in a user message. The `tool_use_id` links this result to the corresponding `ToolUse` block.

The `content` field accepts either a string (the common case) or a list of content blocks (for rich results like text with images). The dialect normalises internally -- wrapping strings in text blocks for providers that need structured content.

The `is_error` boolean flag tells the model the tool use failed. The error details are the content itself -- there's no separate `details` field because the model doesn't need structured exception data, just a message describing what went wrong.

```elixir
# Simple string result
%ToolResult{
  tool_use_id: "call_abc123",
  content: "15C, cloudy with a chance of rain"
}

# Rich result with image
%ToolResult{
  tool_use_id: "call_abc123",
  content: [
    %Content.Text{text: "Here's the forecast chart:"},
    %Content.Attachment{source: {:base64, chart_data}, media_type: "image/png"}
  ]
}

# Error result
%ToolResult{
  tool_use_id: "call_abc123",
  content: "Connection timeout: could not reach weather API",
  is_error: true
}
```

### Summary

| Block | Fields | Appears in |
|-------|--------|------------|
| `Content.Text` | text, signature | User and assistant messages |
| `Content.Thinking` | text, signature | Assistant messages |
| `Content.Attachment` | source, media_type, description, opts | User messages (and tool results) |
| `Content.ToolUse` | id, name, input, signature | Assistant messages |
| `Content.ToolResult` | tool_use_id, content, is_error | User messages |

---

## Streaming

### Overview

The streaming design has three layers, each with a clear responsibility:

1. **Stream parser** (shared) -- decodes raw bytes into individual JSON event maps. `Request.stream/3` selects the parser based on the response `content-type` header: `SSE` for SSE streams (most providers), `NDJSON` for newline-delimited JSON (Ollama).
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
dialect.handle_event/1 (parse to delta tuples)
    │  → [{event_type, event_map}] list
    ▼
provider.modify_events/2 (optional post-dialect augmentation)
    │  → [{event_type, event_map}] list (potentially augmented)
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

Both parsers expose the same `stream/1` interface — accepting an enumerable of binary chunks and returning a stream of decoded JSON maps. `Request.stream/3` selects the parser by checking the response `content-type` header for `"ndjson"`; all other responses default to SSE.

### Dialect event parsing

Each dialect implements a `handle_event/1` callback that receives a single decoded JSON event map and returns a list of normalised delta tuples:

```elixir
@callback handle_event(event :: map()) :: [{atom(), map()}]
```

The return is a list of `{event_type, event_map}` tagged tuples. The function returns `[]` if the event should be dropped. The list form allows a single event to produce multiple deltas (some providers bundle data that maps to separate delta types).

The function is stateless and pure -- it receives one event, returns deltas. No accumulation, no knowledge of what came before. This makes dialects trivially testable: give it a JSON map, assert the tuples that come out.

```elixir
# Anthropic dialect example
def handle_event(%{"type" => "content_block_start", "index" => idx,
                   "content_block" => %{"type" => "text"}}) do
  [{:block_start, %{type: :text, index: idx}}]
end

def handle_event(%{"type" => "content_block_delta", "index" => idx,
                   "delta" => %{"type" => "text_delta", "text" => text}}) do
  [{:block_delta, %{type: :text, index: idx, delta: text}}]
end

def handle_event(%{"type" => "content_block_start", "index" => idx,
                   "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}) do
  [{:block_start, %{type: :tool_use, index: idx, id: id, name: name}}]
end

def handle_event(%{"type" => "message_start", "message" => %{"model" => model}}) do
  [{:message, %{model: model}}]
end

def handle_event(%{"type" => "message_delta",
                   "delta" => %{"stop_reason" => reason}, "usage" => usage}) do
  [{:message, %{stop_reason: normalise_stop_reason(reason), usage: usage}}]
end
```

### Internal delta format

The dialect's normalised delta tuples form the contract between dialects and StreamingResponse. The complete vocabulary:

```elixir
# Stream lifecycle
{:start, %{model: model_id}}
{:done, %{stop_reason: stop_reason, usage: usage_map}}
{:error, reason}

# Content block lifecycle
{:text_start, %{index: integer}}
{:text_delta, %{index: integer, delta: string}}
{:text_end, %{index: integer}}

{:thinking_start, %{index: integer}}
{:thinking_delta, %{index: integer, delta: string}}
{:thinking_end, %{index: integer}}

{:tool_use_start, %{index: integer, id: string, name: string}}
{:tool_use_delta, %{index: integer, delta: string}}
{:tool_use_end, %{index: integer}}
```

The content type is encoded in the event type atom rather than as a separate field. This means every delta is self-describing -- you can pattern match a single event without tracking state from previous events.

Tool call deltas carry string fragments of the JSON-encoded input. The accumulation layer (StreamingResponse) is responsible for joining and parsing the complete JSON into a map.

### Consumer-facing event format

The `StreamingResponse` enumerable yields events as three-element tuples: `{event_type, event_map, partial_response}`. The event type and map mirror the dialect's delta format, with the partial `%Response{}` appended as the third element:

```elixir
{:text_delta, %{index: 0, delta: "Hello"}, %Response{...}}
{:text_start, %{index: 0}, %Response{...}}
{:text_end, %{index: 0, content: "Hello world"}, %Response{...}}
{:thinking_delta, %{index: 1, delta: "Let me think..."}, %Response{...}}
{:tool_use_start, %{index: 2, id: "call_123", name: "weather"}, %Response{...}}
{:tool_use_delta, %{index: 2, delta: "{\"city\":"}, %Response{...}}
{:tool_use_end, %{index: 2, tool_use: %ToolUse{...}}, %Response{...}}
{:done, %{stop_reason: :stop}, %Response{...}}
{:error, {:stream_error, reason}, %Response{...}}
```

The `_end` events carry the completed value for that content block -- the full text string, parsed `ToolUse` struct, etc. Consumers who don't want to process deltas can listen only for `_end` events and get finished content blocks.

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

**Pre-stream errors** surface as `{:error, reason}` from `stream_text/3`. These include model not found (`{:error, {:unknown_model, ...}}`), validation failures, authentication errors (`{:error, :no_api_key}`), and non-200 status codes (`{:error, {:http_error, status, body}}`). The stream never starts.

**Mid-stream errors** (provider errors partway through a streaming response) are wrapped as `{:error, {:stream_error, message}, partial_response}` events through the enumeration, after which the stream terminates. The `{:stream_error, message}` tuple distinguishes mid-stream errors from pre-stream errors at the call site. All dialect `handle_event/1` callbacks emit raw `{:error, message}` deltas; `StreamingResponse` wraps these into `{:stream_error, message}` during processing.

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

`Omni.stream_text/3` is a thin orchestration wrapper. It resolves the model, coerces the context, and delegates to `Omni.Request.build/3` and `Omni.Request.stream/3`. All request construction, validation, and event pipeline composition lives in `Omni.Request`. The code below is illustrative pseudocode showing the key flow -- not the exact implementation:

```elixir
# In Omni:
def stream_text(model, context, opts \\ [])

def stream_text({_, _} = model, context, opts) do
  with {:ok, model} <- get_model(model) do
    stream_text(model, context, opts)
  end
end

def stream_text(%Omni.Model{} = model, context, opts) do
  context = Context.new(context)
  {raw, opts} = Keyword.pop(opts, :raw, false)

  with {:ok, req} <- Request.build(model, context, opts) do
    Request.stream(req, model, raw: raw)
  end
end

# In Omni.Request:
def build(model, context, opts) do
  with {:ok, opts} <- validate(model, opts) do
    {plug, opts} = Map.pop(opts, :plug)
    {timeout, opts} = Map.pop(opts, :timeout)

    body = model.dialect.handle_body(model, context, opts)
    body = model.provider.modify_body(body, context, opts)
    path = model.dialect.handle_path(model, opts)
    url = model.provider.build_url(path, opts)

    req =
      Req.new(method: :post, url: url, json: body, into: :self, receive_timeout: timeout)
      |> apply_headers(opts.headers)
      |> maybe_merge_plug(plug)

    model.provider.authenticate(req, opts)
  end
end

def stream(req, model, opts \\ []) do
  raw? = Keyword.get(opts, :raw, false)

  with {:ok, resp} <- Req.request(req),
       :ok <- check_status(resp) do
    parser = select_parser(resp)  # SSE or NDJSON based on content-type

    deltas =
      resp.body
      |> parser.stream()
      |> Stream.flat_map(&parse_event(model, &1))

    cancel = fn -> Req.cancel_async_response(resp) end
    raw = if raw?, do: {req, resp}

    {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
  end
end
```

The key architectural points:

- **Model resolution is a separate clause.** The tuple `{:anthropic, "claude-sonnet-4-20250514"}` is resolved via `get_model/1` (a `:persistent_term` lookup), then the resolved `%Model{}` falls through to the main clause. No resolution step needed when the caller already has a model struct.

- **Provider and dialect come from the model.** The `%Model{}` struct carries module references for both provider and dialect. `model.provider` and `model.dialect` are immediately callable.

- **`stream_text` is a thin composition layer.** It resolves the model, coerces the context, pops `:raw`, then delegates to `Request.build/3` and `Request.stream/3`. All orchestration logic lives in `Omni.Request`.

- **`Request.build/3` calls `validate/2` internally.** `validate` pops config keys (`api_key`, `base_url`, `headers`) and framework keys (`plug`) from the keyword list, validates the remaining inference opts via Peri in strict mode, three-tier merges config values (call-site > app config > provider default), and returns a unified opts map with everything combined. All callbacks receive this single map.

- **Unified opts map.** All callbacks (`handle_body`, `modify_body`, `build_url`, `authenticate`) receive the same opts map containing both config and inference options. `modify_body` additionally receives the `%Context{}` for per-message transformations. Each reads the keys it needs and ignores the rest. This eliminates separate `split_request_config` and `merge_config` functions.

- **`:timeout` with a generous default.** Defaults to 300,000ms (5 minutes). Maps to Req's `receive_timeout`. LLM APIs routinely exceed Req's default 15s, especially extended thinking models. Popped in `build` and applied to the Req request.

- **Status check catches HTTP errors early.** After `Req.request/1` returns, `check_status/1` verifies the response is 200. Non-200 responses (400, 401, 429, 500, etc.) are read and turned into `{:error, reason}` before any streaming begins.

- **The event stream is lazy composition.** `resp.body` is a `Req.Response.Async` enumerable that yields raw binary chunks. The selected parser (`SSE.stream/1` or `NDJSON.stream/1`) transforms these into decoded JSON event maps. `Request.parse_event/2` composes `dialect.handle_event/1` and `provider.modify_events/2`. Nothing executes until the consumer drives the stream.

- **`validate/2` and `parse_event/2` are `@doc false` public functions.** Exposed for unit testing — `validate` for config merging and schema validation, `parse_event` for the event pipeline composition. The public API is `build/3` and `stream/3`.

- **StreamingResponse is generic.** It receives pre-built delta tuples and builds the consumer event pipeline at construction time via `Stream.transform/5`. Its `Enumerable` implementation delegates directly to this pipeline. The struct holds only two fields: `stream` (the pipeline) and `cancel` (an opaque function). Model, raw HTTP data, and accumulation state are baked into the transform closure. It has no knowledge of providers, dialects, or HTTP.

### High-level flow diagram

```
Omni.stream_text(model, context, opts)
├── 1. Resolve model ({provider, id} tuple → %Model{})
├── 2. Coerce context (string/list → %Context{})
├── 3. Pop :raw from opts
├── 4. Request.build(model, context, opts)
│     ├── Request.validate(model, opts)
│     │     ├── Pop config keys (api_key, base_url, headers) and framework keys (plug)
│     │     ├── Validate inference opts via Peri (strict mode)
│     │     ├── Three-tier merge config: call-site > app config > provider default
│     │     └── Return unified map: %{api_key: ..., base_url: ..., max_tokens: 4096, ...}
│     ├── Pop plug and timeout from unified map
│     ├── dialect.handle_body(model, context, opts) → body map
│     ├── provider.modify_body(body, context, opts) → modified body
│     ├── dialect.handle_path(model, opts) → path
│     ├── provider.build_url(path, opts) → URL
│     ├── Req.new(url, method: :post, json: body, into: :self, receive_timeout: timeout)
│     ├── apply_headers(req, opts.headers) + maybe_merge_plug(plug)
│     └── provider.authenticate(req, opts) → {:ok, req}
├── 5. Request.stream(req, model, raw: raw)
│     ├── Req.request(req) → {:ok, resp}
│     │     Returns immediately; resp.body is Req.Response.Async
│     ├── check_status(resp) → :ok | {:error, ...}
│     ├── select_parser(resp) → SSE or NDJSON (by content-type)
│     ├── parser.stream(resp.body)
│     ├── Stream.flat_map: Request.parse_event(model, event)
│     │     ├── dialect.handle_event(event) → deltas
│     │     └── provider.modify_events(deltas, event) → deltas
│     └── StreamingResponse.new(stream, model: model, cancel: cancel, raw: raw)
│           Builds consumer event pipeline via Stream.transform/5
│           Enumerable impl delegates to pre-built pipeline
│           Yields {event_type, event_map, partial_response} to consumer
│           cancel/1 invokes opaque cancel function
└── Return {:ok, StreamingResponse.t()} | {:error, term()}
```

---

## Module Structure

```
lib/omni.ex                    # Top-level API: generate_text, stream_text,
                               #   get_model, list_models, etc.
lib/omni/
├── application.ex             # OTP Application: loads providers into :persistent_term
├── model.ex                   # Model struct definition
├── context.ex                 # Context struct definition
├── message.ex                 # Message struct (role, content blocks, timestamp)
├── response.ex                # Response struct (message envelope with metadata)
├── streaming_response.ex      # StreamingResponse struct, Enumerable impl,
│                              #   complete/1, cancel/1
├── usage.ex                   # Usage struct (token counts and computed costs)
├── tool.ex                    # Tool struct, behaviour, use macro, execute/2
├── tool/
│   └── schema.ex              # JSON Schema builder functions
├── content/
│   ├── text.ex                # Text content block
│   ├── thinking.ex            # Thinking/reasoning content block
│   ├── attachment.ex          # Generic attachment (images, PDFs, audio)
│   ├── tool_use.ex            # Tool use content block
│   └── tool_result.ex         # Tool result content block
├── sse.ex                     # SSE stream parser (framing, decoding, buffering)
├── ndjson.ex                  # NDJSON stream parser (Ollama)
├── request.ex                 # Request orchestration: build/3, stream/3,
│                              #   validate/2, parse_event/2
├── provider.ex                # Provider behaviour, default implementations,
│                              #   resolve_auth/1, load/1, load_models/2
├── providers/
│   ├── anthropic.ex
│   ├── openai.ex
│   ├── ollama.ex
│   └── ...
├── dialect.ex                 # Dialect behaviour definition
├── dialects/
│   ├── anthropic_messages.ex
│   ├── openai_completions.ex
│   ├── ollama_chat.ex
│   └── ...
└── auth.ex                    # API key resolution logic
```

