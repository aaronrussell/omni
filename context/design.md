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

The relationship: there are ~4-5 dialects, ~20-30 providers (each speaking one dialect), and hundreds of models (each belonging to one provider).

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
  thinking: true,
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

Provider-specific options (like `thinking`, `tool_choice`, `effort`) are passed through without transformation. Each dialect/provider declares which options it supports via an `option_schema/0` callback, enabling helpful validation error messages (e.g. "you passed `thinking: true` but the OpenAI dialect doesn't support that option"). Option validation is handled using the Peri library for schema-based validation.

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

The `provider` and `dialect` fields store full module references, not shorthand atoms. This means a resolved model is self-contained -- it can be used to call provider and dialect callbacks directly without any runtime module resolution step. The shorthand atom (`:anthropic`) exists only as a human-friendly key for lookups and config, declared once on the provider module via `use Omni.Provider`.

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

    for provider_mod <- providers do
      models = provider_mod.models()
      model_map = Map.new(models, &{&1.id, &1})
      :persistent_term.put({Omni, provider_mod.id()}, model_map)
    end
  end
end
```

Which providers are loaded is controlled by application config:

```elixir
config :omni, providers: [
  Omni.Providers.Anthropic,
  Omni.Providers.OpenAI,
  Omni.Providers.Groq
]
```

If no providers are configured, a sensible default set is loaded (Anthropic, OpenAI, etc.), so the library works out of the box without requiring any config. Custom providers are loaded identically to built-in providers -- the startup code just calls `models/0` on each module.

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

The separation from dialects exists because the mapping is many-to-one. There are ~4-5 wire formats but ~20-30 services. Groq, Together, Fireworks, OpenRouter, DeepSeek, and a dozen others all speak the same OpenAI Chat Completions wire format. Their request bodies are identical. Their streaming events have the same JSON schema. The only things that differ are: where you send the request, how you authenticate, and maybe a handful of quirks.

### The Omni.Provider module

`Omni.Provider` serves as both the behaviour definition and the home for shared logic that all providers use. This includes:

- The provider behaviour and `__using__` macro with default implementations
- Model data loading logic (`load_models/1` -- reading JSON, building model structs)
- Shared HTTP request logic used by all providers (built on the Req library)
- The `Omni.Provider.stream/4` function for making authenticated streaming requests directly

### Provider declaration

Each provider module uses `use Omni.Provider` with required identity options and an optional data file path:

```elixir
defmodule Omni.Providers.Anthropic do
  use Omni.Provider,
    id: :anthropic,
    dialect: Omni.Dialects.AnthropicMessages,
    models_file: "priv/models/anthropic.json"
end
```

The `use` macro generates `id/0` and `dialect/0` accessor functions from the provided values. The `:id` and `:dialect` options are required -- every provider must declare its shorthand identifier and which dialect it speaks. The `:models_file` option is optional -- it specifies the path to a JSON data file containing the provider's model catalog.

### Provider behaviour callbacks

The provider behaviour defines the following callbacks:

| Callback | Returns | Default | Purpose |
|----------|---------|---------|---------|
| `config/0` | `map()` | *required* | Base URL, auth header name, auth default value |
| `option_schema/0` | `map()` | `%{}` | Peri schema declaring provider-specific options |
| `models/0` | `[%Model{}]` | Calls `Provider.load_models/1` | Returns the provider's model list |
| `build_url/2` | `String.t()` | Concatenation | Builds full URL from base URL and dialect path |
| `authenticate/2` | `{:ok, Req.Request.t()} \| {:error, reason}` | API key header | Adds auth to a Req request |
| `adapt_body/2` | `map()` | Passthrough | Adapts the dialect-built request body for this provider |
| `adapt_event/1` | `map()` | Passthrough | Adapts an SSE event map for this provider |

**Which callbacks can fail:** Only `authenticate/2` returns an ok/error tuple, because authentication involves real external dependencies that can fail at runtime (missing environment variables, unreachable vaults, expired tokens). All other callbacks either return static data or perform deterministic transformations on already-validated inputs.

### Provider config

Each provider defines a `config/0` function returning a map of structural and default configuration:

```elixir
defmodule Omni.Providers.Anthropic do
  use Omni.Provider,
    id: :anthropic,
    dialect: Omni.Dialects.AnthropicMessages,
    models_file: "priv/models/anthropic.json"

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

Each provider has a `models/0` callback that returns its list of `%Model{}` structs. The default implementation calls `Omni.Provider.load_models/1`, which checks for the `:models_file` attribute and loads the JSON data:

```elixir
# Default implementation generated by `use Omni.Provider`
def models do
  Omni.Provider.load_models(__MODULE__)
end
```

`Omni.Provider.load_models/1` reads the declared `:models_file` path, parses the JSON, and builds `%Model{}` structs stamped with the provider's module and dialect:

```elixir
def load_models(module) do
  case module.__omni_models_file__() do
    nil -> []
    path -> load_from_json(module, path)
  end
end
```

Custom providers can override `models/0` to return models from any source:

```elixir
defmodule MyApp.Providers.Internal do
  use Omni.Provider,
    id: :internal,
    dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def models do
    [
      %Model{
        id: "our-fine-tuned-model",
        provider: __MODULE__,
        dialect: dialect(),
        context_window: 128_000,
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

`use Omni.Provider` provides a default implementation that resolves an API key and adds it as a header, which covers the majority of providers. Providers with exotic auth (like Bedrock) override the callback entirely.

### API key resolution

API keys can be provided in multiple ways, resolved in priority order:

1. **Call-time opts** -- passed directly when making a request (for multi-tenant apps)
2. **Application config** -- set in `config.exs`
3. **Provider default** -- the fallback defined in the provider's config

Supported value formats:

- `"sk-ant-..."` -- a literal string
- `{:system, "ENV_VAR_NAME"}` -- an environment variable
- `{Module, :function, [args]}` -- an MFA tuple for dynamic resolution (vault, secrets manager)

### Provider config overrides

Deployment-specific values like `base_url` and `api_key` can be overridden via application config without modifying the provider module:

```elixir
config :omni, :providers,
  openai: [
    api_key: {:system, "AZURE_OPENAI_KEY"},
    base_url: "https://my-instance.openai.azure.com"
  ]
```

The principle: provider modules define the **structural contract** (header name, dialect, URL path structure) and **sensible defaults**. Everything deployment-specific is overridable.

### URL building

The `build_url/2` callback constructs the full URL from the provider's base URL and the path built by the dialect. The default implementation is simple concatenation:

```elixir
def build_url(base_url, path) do
  base_url <> path
end
```

Providers that restructure URLs (e.g. Azure OpenAI, which reorganises the path around deployment names and API versions) override this callback entirely.

### Provider adaptations

Some providers speak a standard dialect but with minor deviations -- an extra required field, a parameter that needs renaming, a slightly different event envelope. Two optional callbacks handle this:

- **`adapt_body/2`** -- receives the dialect-built request body and the merged opts keyword list (containing inference options, provider options, and request config). The provider pulls out whatever it needs. Returns the adjusted body. Default is passthrough.
- **`adapt_event/1`** -- receives an SSE event map, returns the adjusted event map. Default is passthrough.

These are *adaptations* of the dialect's standard output, not alternatives to it. The dialect does the real transformation; the provider makes small, targeted adjustments. Most providers don't need either callback.

### Direct provider usage

The provider can be used independently to make authenticated streaming HTTP requests. This is useful for testing, debugging, and advanced use cases where the caller has a provider-native request body:

```elixir
# Direct provider usage -- no dialect, no Omni types
Omni.Provider.stream(:anthropic, "/v1/messages", %{
  "model" => "claude-sonnet-4-20250514",
  "messages" => [%{"role" => "user", "content" => "Hi"}],
  "max_tokens" => 100,
  "stream" => true
}, api_key: "sk-...")
```

`Omni.Provider.stream/4` takes a provider (module or shorthand atom), a path, a body map, and a keyword list of options (including Req options like `into:`, plus `api_key:`, `base_url:`, etc.). It handles URL building, authentication, and the HTTP request via Req. The caller supplies the path and body in the provider's native format. This makes the provider layer independently testable without involving dialects or Omni's type system.

### Custom providers

Users implement custom provider modules using the same behaviour:

```elixir
defmodule MyApp.Providers.Internal do
  use Omni.Provider,
    id: :internal,
    dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://internal-llm.company.com",
      auth_header: "authorization",
      auth_default: {:system, "INTERNAL_LLM_KEY"}
    }
  end

  @impl true
  def models do
    [%Model{id: "our-model", provider: __MODULE__, dialect: dialect(), ...}]
  end
end
```

Custom providers are registered in the application config alongside built-in providers:

```elixir
config :omni, providers: [
  Omni.Providers.Anthropic,
  Omni.Providers.OpenAI,
  MyApp.Providers.Internal
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
| `build_path/1` | `String.t()` | Builds the URL path from the model |
| `build_body/3` | `{:ok, map()} \| {:error, reason}` | Builds the request body from model, context, and options |
| `parse_event/1` | `{atom(), map()} \| nil` | Transforms a decoded SSE event map into a normalised delta tuple |

**Which callbacks can fail:** Only `build_body/3` returns an ok/error tuple. This is the first place that the *context content* is examined against the dialect's capabilities -- an audio attachment on a dialect that doesn't support audio, a thinking block passed to a dialect that can't handle it in multi-turn. These are real "this won't work" scenarios that should produce clear errors, not crashes.

`option_schema/0` returns static data. `build_path/1` is trivial string derivation from a known-good model. `parse_event/1` runs in the streaming process where crashes naturally become error events; the nil return already handles "skip this event."

### Dialect callback details

**`option_schema/0`** -- returns a Peri schema map declaring which options this dialect understands. The orchestration layer merges this with the provider's `option_schema/0` and a base request schema, then validates the full options keyword list in a single pass before any work begins.

**`build_path/1`** -- receives a `%Model{}` struct and returns the URL path string. This is typically a static path with the model ID interpolated for some API families:

```elixir
# Anthropic Messages dialect
def build_path(_model), do: "/v1/messages"

# OpenAI Completions dialect
def build_path(_model), do: "/v1/chat/completions"
```

**`build_body/3`** -- receives a `%Model{}`, `%Context{}`, and validated options keyword list. Returns `{:ok, body_map}` or `{:error, reason}`. This is where Omni's types become the provider's native JSON structure -- messages are reshaped, content blocks are encoded, tools are serialized, and options are mapped to API parameters.

```elixir
# Simplified example
def build_body(model, context, opts) do
  {:ok, %{
    "model" => model.id,
    "messages" => encode_messages(context.messages),
    "system" => context.system,
    "max_tokens" => Keyword.get(opts, :max_tokens, model.max_output_tokens),
    "temperature" => Keyword.get(opts, :temperature),
    "stream" => true
  }}
end
```

**`parse_event/1`** -- receives a single decoded JSON event map (from the SSE parser) and returns a normalised `{event_type, event_map}` delta tuple, or `nil` to skip the event. The function is stateless and pure -- it receives one event, returns one delta. No accumulation, no knowledge of what came before. This makes dialects trivially testable: give it a JSON map, assert the tuple that comes out.

```elixir
# Anthropic dialect example
def parse_event(%{"type" => "content_block_delta", "index" => idx,
                  "delta" => %{"type" => "text_delta", "text" => text}}) do
  {:text_delta, %{index: idx, delta: text}}
end

def parse_event(%{"type" => "message_delta",
                  "delta" => %{"stop_reason" => reason}, "usage" => usage}) do
  {:done, %{stop_reason: normalise_stop_reason(reason), usage: usage}}
end
```

### Option validation

The valid option set for any request is a *composition* of three layers: options the dialect handles (temperature, max_tokens), options the provider handles (thinking, effort), and options the request layer handles (api_key, base_url, raw). No single layer knows the full picture.

Each layer declares what it accepts via `option_schema/0`. The orchestration layer merges these into one Peri schema and validates the full options keyword list in a single pass. One validation call, one error surface. Each callback that *receives* options (`build_body`, `adapt_body`, `authenticate`) can trust that they're already validated.

**Implementation note:** The exact shape of `option_schema/0` return values and the merging strategy need to be worked out during implementation. The intent is clear -- each layer declares a Peri schema map of what it accepts, and these are merged and validated once -- but the details of how universal options (temperature, max_tokens) compose with dialect-specific and provider-specific options may require iteration. For example, a dialect might declare `%{temperature: {:float, []}, max_tokens: {:integer, []}}` while a provider adds `%{thinking: {:boolean, []}}`. How overlaps are handled (if both dialect and provider declare the same key) is an implementation detail to resolve.

Dialect output (the request body) is not validated at runtime. If a dialect produces malformed output, that's a bug in the library caught by tests, not a runtime concern.

### Relationship to providers

Many providers share a dialect. For example, Groq, Together, Fireworks, and OpenRouter all use the OpenAI Chat Completions dialect. The provider references its dialect via `use Omni.Provider`, and the orchestration layer calls the dialect for data transformation and the provider for configuration and auth.

### Testability

Each layer is testable independently:

```elixir
# Test a dialect in pure isolation -- no HTTP, no provider
body = AnthropicMessages.build_body(model, context, opts)
assert body["messages"] == [...]

delta = AnthropicMessages.parse_event(%{"type" => "content_block_delta", ...})
assert delta == {:text_delta, %{index: 0, delta: "Hello"}}

# Test a provider in isolation -- real HTTP, native body
{:ok, stream} = Omni.Provider.stream(:anthropic, "/v1/messages", %{
  "model" => "claude-sonnet-4-20250514",
  "messages" => [%{"role" => "user", "content" => "Hi"}],
  "max_tokens" => 100,
  "stream" => true
}, api_key: "sk-...")

# Test the full stack
{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-20250514"}, "Hi")
```

The dialect is pure functions (maps in, maps out). The provider is a thin authenticated HTTP client. The top-level API composes them.

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
    :error,         # nil | String.t()
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

**Implementation note:** Since all requests use streaming HTTP under the hood, the `raw` option requires the spawned streaming process to capture the Req request and response structs and send them back to the caller when the stream completes. `Omni.Provider.stream/4` may need to be structured so that the Req request is built as a separate step before execution, allowing the request struct to be captured. The Req response from a streaming request will be available after the stream finishes. The exact plumbing is an implementation detail, but the contract is that `raw: true` populates `{%Req.Request{}, %Req.Response{}}` on the final `%Response{}` struct.

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

Raw JSON Schema is verbose and error-prone. `Omni.Tool.Schema` provides plain builder functions that return standard JSON Schema maps:

```elixir
defmodule Omni.Tool.Schema do
  def object(properties, opts \\ [])
  def string(opts \\ [])
  def number(opts \\ [])
  def integer(opts \\ [])
  def boolean(opts \\ [])
  def array(items, opts \\ [])
  def enum(values, opts \\ [])
end
```

Used with import:

```elixir
import Omni.Tool.Schema

input_schema = object(%{
  city: string(description: "The city name"),
  units: enum(["celsius", "fahrenheit"])
}, required: [:city])
```

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

For reusable, self-contained tools, the `Omni.Tool` behaviour and `use Omni.Tool` macro provide a module-based pattern. Name and description are passed as arguments to `use` (they're static configuration, not behaviour), while `input_schema/0`, `init/1`, and `call/1,2` are callbacks:

```elixir
defmodule MyWeatherTool do
  use Omni.Tool,
    name: "get_weather",
    description: "Get current weather for a city"

  @impl true
  def input_schema do
    import Omni.Tool.Schema
    object(%{
      city: string(description: "The city name"),
      units: enum(["celsius", "fahrenheit"])
    }, required: [:city])
  end

  @impl true
  def call(input) do
    WeatherAPI.get(input["city"], input["units"])
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
  opts = init(args)
  %Tool{
    name: name(),
    description: description(),
    input_schema: input_schema(),
    handler: fn input -> call(input, opts) end
  }
end
```

### Stateful tools

Tool modules support an `init/1` callback for tools that need external state. The default implementation is a passthrough. When overridden, it receives arguments passed to `new/1` and returns opts that are passed as the second argument to `call/2`:

```elixir
defmodule AgeTool do
  use Omni.Tool,
    name: "get_age",
    description: "Get a user's age by name"

  @impl true
  def input_schema do
    import Omni.Tool.Schema
    object(%{name: string()}, required: [:name])
  end

  @impl true
  def init(age_map) when is_map(age_map), do: %{age_map: age_map}

  @impl true
  def call(input, opts) do
    Map.get(opts.age_map, input["name"])
  end
end

tool = AgeTool.new(%{"joe" => 42, "alice" => 37})
```

The `init/1` callback is the place to validate and fail early -- at tool construction time rather than mid-conversation when the model tries to use the tool.

For stateless tools, `call/2` has a default implementation that delegates to `call/1`, so authors can ignore opts entirely.

### Tool execution

`Omni.Tool.execute/2` dispatches a tool use to the tool's handler:

```elixir
result = Omni.Tool.execute(tool, tool_use.input)
```

This is a thin helper that calls `tool.handler.(input)`, raising a clear error if the handler is nil. The `generate_text` and `stream_text` functions do not execute tools -- they are pure request/response functions. Tool execution is the caller's responsibility, with `Omni.Tool.execute/2` as a convenience.

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

1. **SSE parser** (shared) -- decodes raw SSE bytes into individual JSON event maps
2. **Dialect** (per-API-family) -- transforms a JSON event map into a normalised delta tuple
3. **StreamingResponse** (shared) -- accumulates deltas into a partial response, emits rich consumer events

The event pipeline inside the streaming process flows through the Req `:into` callback:

```
Req chunks (raw bytes)
    │
    ▼
SSE parser (shared, stateful for framing)
    │  → decoded JSON map (one at a time)
    ▼
Provider.adapt_event/1 (optional, default passthrough)
    │  → adjusted JSON map
    ▼
Dialect.parse_event/1 (stateless, pure)
    │  → {event_type, event_map} delta tuple
    ▼
Delta sent as message to caller process
    │
    ▼
StreamingResponse Enumerable.reduce/3 (in caller process)
    │  → receives delta messages via monitor ref
    │  → maintains accumulator (partial Response)
    │  → yields {event_type, event_map, partial_response}
    ▼
Consumer receives rich events
```

**Process boundaries:** The SSE parsing, event adaptation, and dialect parsing all happen inside the **spawned process**, within a Req `:into` callback handler composed at the `stream_text` level. Each parsed delta is sent as a message to the **caller process**. The caller's `Enumerable.reduce/3` receives these messages (matched on the monitor ref), accumulates the partial Response, and yields events to the consumer. The spawned process is a producer; the caller process is the consumer. If the caller dies, the spawned process detects it via its monitor and self-terminates. If the spawned process crashes, the caller receives a `:DOWN` message which translates to an error event in the enumeration.

StreamingResponse itself is a generic mechanism -- it receives pre-parsed delta tuples and accumulates them, with no knowledge of providers, dialects, or HTTP.

### StreamingResponse

`Omni.StreamingResponse` is a struct that implements the `Enumerable` protocol. It is returned by `stream_text` and serves as both the iterable and the cancellation handle.

```elixir
defmodule Omni.StreamingResponse do
  defstruct [:pid, :ref]
end

defimpl Enumerable, for: Omni.StreamingResponse do
  # Receives delta messages from the spawned process
  # Maintains accumulation state (partial Response)
  # Yields rich consumer events
end
```

The struct holds a `pid` (for cancellation) and a `ref` (for receiving messages and detecting crashes via monitor). Consumers interact with it as a standard enumerable:

```elixir
{:ok, stream} = Omni.stream_text(model, context)

# Use directly as an enum -- pattern match for what you need
Enum.each(stream, fn
  {:text_delta, %{delta: delta}, _partial} -> IO.write(delta)
  _ -> :ok
end)

# Accumulate into a complete Response
{:ok, stream} = Omni.stream_text(model, context)
{:ok, response} = Omni.StreamingResponse.complete(stream)

# Cancel a stream
Omni.StreamingResponse.cancel(stream)
```

**Why not a Task?** Task's value proposition is async/await and structured concurrency (linking to the caller). Neither applies here -- the consumption model is message receiving, not awaiting, and if the stream process crashes the caller should get an error through the enumeration, not crash itself. A raw spawned process with bidirectional monitors gives the right failure semantics: a `:DOWN` message translates to an error event, and if the caller dies, the stream process detects it and self-terminates.

### SSE parser

A shared SSE parser sits between Req and the dialect. It handles all framing concerns: buffering incomplete events across TCP chunks, splitting multi-event payloads, stripping `data:` prefixes, detecting `[DONE]` sentinels, filtering pings/keepalives, and decoding JSON. What it hands to the dialect is a single decoded map per event.

The SSE parser is shared across all dialects. If a provider does something non-standard at the SSE level, that can be handled by a parser option or a provider callback, but the common case is standard SSE framing.

### Dialect event parsing

Each dialect implements a `parse_event/1` callback that receives a single decoded JSON event map and returns a normalised delta tuple:

```elixir
@callback parse_event(event :: map()) :: {atom(), map()} | nil
```

The return is a `{event_type, event_map}` tagged tuple. The function returns `nil` if the event should be dropped (an edge case -- the SSE parser filters most non-content events, but the callback allows for it).

The function is stateless and pure -- it receives one event, returns one delta. No accumulation, no knowledge of what came before. This makes dialects trivially testable: give it a JSON map, assert the tuple that comes out.

```elixir
# Anthropic dialect example
def parse_event(%{"type" => "content_block_start", "index" => idx,
                  "content_block" => %{"type" => "text"}}) do
  {:text_start, %{index: idx}}
end

def parse_event(%{"type" => "content_block_delta", "index" => idx,
                  "delta" => %{"type" => "text_delta", "text" => text}}) do
  {:text_delta, %{index: idx, delta: text}}
end

def parse_event(%{"type" => "content_block_start", "index" => idx,
                  "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}) do
  {:tool_use_start, %{index: idx, id: id, name: name}}
end

def parse_event(%{"type" => "message_start", "message" => %{"model" => model}}) do
  {:start, %{model: model}}
end

def parse_event(%{"type" => "message_delta",
                  "delta" => %{"stop_reason" => reason}, "usage" => usage}) do
  {:done, %{stop_reason: normalise_stop_reason(reason), usage: usage}}
end
```

### Internal delta format

The dialect's normalised delta tuples form the contract between dialects and StreamingResponse. The complete vocabulary:

```elixir
# Stream lifecycle
{:start, %{model: model_id}}
{:done, %{stop_reason: stop_reason, usage: usage_map}}
{:error, %{reason: reason}}

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
{:error, %{reason: reason}, %Response{...}}
```

The `_end` events carry the completed value for that content block -- the full text string, parsed `ToolUse` struct, etc. Consumers who don't want to process deltas can listen only for `_end` events and get finished content blocks.

**Partial response on every event.** The partial `%Response{}` is accumulated by the `StreamingResponse` as events arrive. Elixir's structural sharing means this is memory-efficient -- each update creates a new struct shell pointing to mostly the same underlying data. Consumers who don't need the partial response simply ignore it with an underscore in pattern matches:

```elixir
# Just stream text to the console
Enum.each(stream, fn
  {:text_delta, %{delta: delta}, _} -> IO.write(delta)
  _ -> :ok
end)

# Build a UI showing the full response state as it streams
Enum.each(stream, fn
  {_type, _event, partial} -> update_ui(partial)
end)

# Wait for tool uses to complete
Enum.each(stream, fn
  {:tool_use_end, %{tool_use: tool_use}, _} -> execute_tool(tool_use)
  _ -> :ok
end)
```

### Error handling

Errors are categorised into two surfaces:

**Pre-stream errors** surface as `{:error, reason}` from `stream_text/3`. These include model not found, validation failures, authentication errors, and HTTP status code errors. The stream never starts.

**Mid-stream errors** (connection drops, provider errors partway through) are emitted as `{:error, %{reason: reason}, partial_response}` events through the enumeration, after which the stream terminates.

`StreamingResponse.complete/1` returns `{:ok, %Response{}} | {:error, reason}`. If a mid-stream error occurs, `complete/1` returns `{:error, reason}` -- the partial response is discarded. Consumers who care about partial data under failure should consume the stream manually, where they receive valid chunks followed by the error event.

```elixir
# complete/1 gives clean ok/error semantics
with {:ok, stream} <- Omni.stream_text(model, context),
     {:ok, response} <- Omni.StreamingResponse.complete(stream) do
  response
end

# Manual consumption gives access to partial data on error
Enum.each(stream, fn
  {:error, %{reason: reason}, _partial} -> handle_error(reason)
  {:text_delta, %{delta: delta}, _} -> IO.write(delta)
  _ -> :ok
end)
```

---

## Request Flow

### The stream_text pipeline

`Omni.stream_text/3` is the core orchestration function. It composes the dialect (data transformation) and provider (HTTP) layers into a single pipeline. The code below is illustrative pseudocode showing the key flow -- not the exact implementation. Multiple function clauses handle model resolution separately from the main flow:

```elixir
def stream_text(model, context, opts \\ [])

def stream_text({_, _} = model, context, opts) do
  with {:ok, model} <- get_model(model) do
    stream_text(model, context, opts)
  end
end

def stream_text(%Omni.Model{} = model, context, opts) do
  context = to_context(context)
  provider = model.provider
  dialect = model.dialect

  opts = merge_config(provider, opts)

  with {:ok, opts} <- validate_options(opts, dialect, provider),
       path <- dialect.build_path(model),
       {:ok, body} <- dialect.build_body(model, context, opts),
       body <- provider.adapt_body(body, opts)
  do
    handler = build_stream_handler(provider, dialect)

    Omni.StreamingResponse.new(fn ->
      Omni.Provider.stream(provider, path, body, into: handler)
    end)
  end
end
```

The key architectural points:

- **Model resolution is a separate clause.** The tuple `{:anthropic, "claude-sonnet-4-20250514"}` is resolved via `get_model/1` (a `:persistent_term` lookup), then the resolved `%Model{}` falls through to the main clause. No resolution step needed when the caller already has a model struct.

- **Provider and dialect come from the model.** The `%Model{}` struct carries direct module references. No lookup table, no atom-to-module mapping. `model.provider` and `model.dialect` are immediately callable.

- **`merge_config/2`** merges `provider.config/0` with overrides from application config (keyed by `provider.id()`) and call-time opts (api_key, base_url, headers, etc.) into a single keyword list. The result flows through the pipeline -- each callback that receives `opts` pulls out what it needs. Priority order: call-time opts > application config > provider defaults.

- **Validation happens once, early.** `validate_options/3` merges schemas from `dialect.option_schema/0`, `provider.option_schema/0`, and a base request schema, then runs Peri once. After this point, all callbacks can trust their inputs are valid.

- **The dialect builds, the provider adapts.** `dialect.build_body/3` does the heavy transformation from Omni types to native format. `provider.adapt_body/2` makes small, targeted adjustments for this specific service. Most providers pass through unchanged.

- **The stream handler is composed at this level.** `build_stream_handler/2` returns a Req `:into` callback that captures the provider and dialect via closure. Inside the callback: SSE bytes are decoded, `provider.adapt_event/1` adjusts event maps, `dialect.parse_event/1` produces normalised deltas, and deltas are sent as messages to the StreamingResponse process.

- **StreamingResponse is generic.** `StreamingResponse.new/1` spawns a process, runs the callback (which starts the HTTP stream via `Omni.Provider.stream`), and its `Enumerable` implementation receives delta messages, accumulates the partial Response, and yields three-element consumer tuples. It has no knowledge of providers, dialects, or HTTP.

- **`Omni.Provider.stream/4` is independently usable.** It takes a provider (module or shorthand atom), path, body, and a keyword list of Req options. It handles URL building (`provider.build_url/2`), authentication (`provider.authenticate/2`), and the HTTP request via Req. This can be called directly for testing or advanced use cases where the caller has a provider-native request body.

### High-level flow diagram

```
Omni.stream_text(model, context, opts)
│
├── 1. Resolve model (if tuple, look up from :persistent_term)
│
├── 2. Normalise context (to_context/1)
│
├── 3. Merge config and opts
│     Merge provider.config/0 with app config overrides and call-time opts into single keyword list
│
├── 4. Validate options
│     Merge schemas from dialect, provider, and base request layer
│     Validate via Peri; return {:error, reason} if invalid
│
├── 5. Build path (Dialect)
│     dialect.build_path(model) → "/v1/messages"
│
├── 6. Build body (Dialect)
│     dialect.build_body(model, context, opts) → {:ok, body_map}
│     Transforms Omni types into provider-native JSON structure
│
├── 7. Adapt body (Provider, optional)
│     provider.adapt_body(body, opts) → adjusted body
│     Default: passthrough
│
├── 8. Build stream handler
│     Composes SSE parsing, provider.adapt_event/1, and
│     dialect.parse_event/1 into a single Req :into callback
│
├── 9. Spawn StreamingResponse process
│     └── Inside spawned process:
│         │
│         ├── Omni.Provider.stream(provider, path, body, into: handler)
│         │   ├── provider.build_url(base_url, path) → full URL
│         │   ├── provider.authenticate(req, config) → authenticated req
│         │   └── Req makes HTTP request with :into handler
│         │
│         └── Handler receives streaming chunks:
│             ├── SSE parser decodes raw bytes → JSON event maps
│             ├── provider.adapt_event(event) → adjusted event map
│             ├── dialect.parse_event(event) → {event_type, event_map}
│             └── Delta sent as message to caller
│
└── 10. StreamingResponse Enumerable (in caller process)
        Receives delta messages
        Accumulates partial Response
        Yields {event_type, event_map, partial_response} to consumer
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
├── sse.ex                     # Shared SSE parser (framing, decoding, buffering)
├── provider.ex                # Provider behaviour, default implementations,
│                              #   shared HTTP logic, load_models/1, stream/4
├── providers/
│   ├── anthropic.ex
│   ├── openai.ex
│   ├── groq.ex
│   └── ...
├── dialect.ex                 # Dialect behaviour definition
├── dialects/
│   ├── anthropic_messages.ex
│   ├── openai_completions.ex
│   └── ...
└── auth.ex                    # API key resolution logic
```

---

## Future Considerations

### Automated tool calling

`generate_text` and `stream_text` are single request/response primitives. If the model's response contains tool use blocks, it is the caller's responsibility to execute the tools, update the context with the results, and make another request. This is deliberate -- single-request functions are predictable in cost, latency, and side effects.

A future addition will provide separate functions that loop over the single-request primitives, automatically executing tools and continuing the conversation until the model produces a final response (or a step limit is reached). These will be distinct functions, not options on the existing ones, because a function that sometimes makes one request and sometimes makes ten has fundamentally different semantics. The naming and exact API shape are topics for future design work.

### Agents

Beyond automated tool calling, there is a third level of interaction: agents. An agent builds on the tool calling loop but adds goal-orientation, step-level hooks (logging, budget enforcement, human approval gates), error recovery policies, and structured observability of the execution trace. The key distinction is that a tool loop is reactive machinery (continue if there are tool use blocks, stop if there aren't), while an agent makes decisions about how to pursue a goal.

This needs further research to flesh out, but the architectural intent is a layered design: single-request primitives at the base, a tool calling loop built on top, and agent capabilities built on top of the loop. Each layer composes over the one below it.

---

## Open Questions

### Option schema composition

The `option_schema/0` callback on both Dialect and Provider behaviours returns a Peri schema map. How these schemas are merged, how universal options (temperature, max_tokens) are declared (on a base schema? on the dialect?), and how conflicts between layers are handled needs to be worked out during implementation. See the implementation note in the [Option validation](#option-validation) section.

### Raw option plumbing with streaming-first architecture

The `raw: true` option needs to capture `{%Req.Request{}, %Req.Response{}}` from a streaming HTTP request that runs inside a spawned process. The implementation needs to arrange for these structs to be sent back to the caller and attached to the final `%Response{}`. See the implementation note in the [Raw request/response access](#raw-requestresponse-access) section.

---

## Resolved Decisions

- **Single Message struct** -- one `%Message{}` struct for all roles, not separate `%UserMessage{}`/`%AssistantMessage{}` types. Role differences are expressed through content blocks, not separate struct types.
- **Two roles, not three** -- messages have two roles: `:user` and `:assistant`. There is no `:tool` role. Tool results are content blocks within user messages. This keeps the Message struct minimal, is semantically accurate (tool results are the user's application reporting back), and handles multi-content turns naturally.
- **Structs over plain maps** -- structs provide field validation, typespecs, and compile-time pattern matching safety. Plain maps are too loose for a library.
- **No Records** -- Elixir Records are an Erlang-ism that would confuse users with no upside over structs.
- **Response wraps Message** -- `%Response{}` contains a `%Message{}` rather than duplicating message fields. This makes appending to a conversation thread trivial (`response.message`).
- **Stop reason is response-only** -- stop reason is metadata about the generation event, not conversation data. It is redundant with content blocks (e.g. a tool use block already signals the model used a tool). It does not need to be carried in the message sequence.
- **Timestamps on messages** -- messages carry an optional `timestamp` field as local metadata (when the struct was created). Dialects ignore it. Defaulted lazily via `Message.new/1`.
- **Response naming** -- `%Response{}` is the right name for now. Future generation types (image, audio) would use distinct types since they are structurally different. No need to pre-generalise.
- **Content blocks as structs** -- each content block type is a separate struct under `Omni.Content`. This gives compile-time pattern matching safety, clean per-type field definitions, and a natural module home for block-specific helpers.
- **Five content block types** -- Text, Thinking, Attachment, ToolUse, ToolResult. This covers the cross-provider use cases. Provider-specific block types (citations, redacted thinking) are not included in the unified format.
- **Generic Attachment over separate Image/PDF types** -- a single `Attachment` struct handles all binary content (images, PDFs, audio) via `media_type`. The structural differences between attachment types are minimal (source + media type), and the behavioural differences are the dialect's concern.
- **Tagged tuples for attachment source** -- `{:base64, data} | {:url, url}` rather than separate `source_type` and `data` fields. This makes the relationship between source type and data inseparable and pattern matches cleanly.
- **`media_type` over `mime_type`** -- uses the technically correct IANA terminology and aligns with Anthropic's API naming.
- **`input` over `arguments`/`params` for tool uses** -- `input` is clear, always a parsed map (not a JSON string), and doesn't carry the baggage of OpenAI's string-encoded arguments quirk.
- **`is_error` boolean on tool results** -- a simple flag indicating failure, not a separate error details field. The error message is the content itself. `is_error` is preferred over `error?` because the question mark suffix doesn't work cleanly in struct pattern matching.
- **No `details` field on tool results** -- structured exception data is the user's application concern, not the content block's. The model needs the error message (in content) and the flag (is_error), nothing more.
- **Redacted thinking via nil text** -- when a thinking block's text is `nil`, it's redacted. No separate `redacted` boolean needed since it's directly derivable.
- **StreamingResponse struct with Enumerable** -- `Omni.StreamingResponse` is a struct implementing the `Enumerable` protocol. It serves as both the iterable and the cancellation handle. Consumers use it directly with `Enum`/`Stream` functions, and can cancel via `StreamingResponse.cancel/1`. Named `StreamingResponse` (not `TextStream` or `Stream`) for consistency with `Response` and because the struct is not content-type-specific.
- **Raw spawned process over Task** -- the streaming process is a raw spawned process with bidirectional monitors, not a Task. Task's async/await pattern and caller-linking are wrong for this use case. A monitor gives the right failure semantics: crashes become error events in the enumeration, and if the caller dies the stream process self-terminates.
- **Three-layer streaming architecture** -- streaming has three layers: (1) a shared SSE parser handles framing and JSON decoding, (2) the dialect's `parse_event/1` transforms a JSON map into a normalised delta tuple (stateless, pure), (3) `StreamingResponse` accumulates deltas into a partial response and yields rich consumer events. The dialect never accumulates state; the SSE parser never interprets semantics.
- **Internal delta format as tagged tuples** -- dialects emit `{event_type, event_map}` tuples where the event type atom encodes the content type (`:text_delta`, `:tool_use_start`, etc.). Every delta is self-describing -- consumers can pattern match a single event without tracking state.
- **Consumer events as three-element tuples** -- the `StreamingResponse` enumerable yields `{event_type, event_map, partial_response}`. The first two elements mirror the dialect's delta format; the third is the accumulated `%Response{}` built up as events arrive. Memory overhead is negligible due to Elixir's structural sharing.
- **Partial response on every event** -- every consumer event carries the accumulated partial `%Response{}`. Consumers who don't need it ignore it via underscore. Consumers who do (UI state, agentic loops) get it without reimplementing accumulation logic.
- **`_end` events carry completed values** -- `text_end` carries the full text string, `tool_use_end` carries the parsed `%ToolUse{}` struct. Consumers who don't want to process deltas can listen only for `_end` events.
- **Dialect `parse_event/1` is one-in, one-out** -- receives one decoded JSON event map, returns one `{event_type, event_map}` tuple or `nil`. The SSE parser filters pings/keepalives before they reach the dialect; nil is an edge case escape hatch.
- **Shared SSE parser outside dialects** -- SSE framing (buffering, multi-event splitting, `[DONE]` detection, JSON decoding) is handled once in a shared module. Dialects receive clean, decoded JSON maps. All major LLM APIs use JSON-over-SSE; dialect-specific behaviour is in the JSON schema, not the transport framing.
- **Two error surfaces** -- pre-stream errors (model not found, validation, auth, HTTP status) return `{:error, reason}` from `stream_text/3`. Mid-stream errors (connection drops, provider errors) emit as `{:error, event_map, partial_response}` events through the enumeration.
- **`complete/1` discards partial on error** -- `StreamingResponse.complete/1` returns `{:ok, %Response{}} | {:error, reason}`. Partial data is not surfaced on error. Consumers who need partial data under failure should consume the stream manually.
- **`stream_text` and `generate_text` return ok/error tuples** -- both return `{:ok, result} | {:error, reason}` because errors can occur before streaming begins. This composes cleanly with `with` chains.
- **"Dialect" as the final name** -- "Dialect" describes the concept well (a variation of a shared language), has been the working name throughout design, and none of the alternatives were better. Protocol conflicts with Elixir, Adapter better fits the provider layer, and Codec/Client/Format/Spec are less expressive.
- **"Tool use" over "tool call"** -- `Content.ToolUse` and `Content.ToolResult`, `:tool_use` as a stop reason, `:tool_use_start`/`:tool_use_delta`/`:tool_use_end` as streaming events. "Tool calling" is an awkward holdover from OpenAI's original "function calling" terminology. "Use" is the natural verb -- you use a tool, you don't call it. Aligns with Anthropic's API naming.
- **Raw request/response via option flag** -- passing `raw: true` in options populates the `raw` field on the `%Response{}` struct with `{%Req.Request{}, %Req.Response{}}`. Default is `nil`. The raw Req structs are stored directly rather than extracting fields -- the point of the escape hatch is access to what actually happened on the wire, not another abstraction layer.
- **Flat Usage struct with computed costs** -- `%Usage{}` has flat fields for token counts (`input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `total_tokens`) and computed costs (`input_cost`, `output_cost`, `cache_read_cost`, `cache_write_cost`, `total_cost`). Flat rather than nested maps (`tokens: %{...}, cost: %{...}`) to preserve struct-level field validation. Costs are computed automatically from model pricing data, not left to consumers. `Usage.add/2` supports accumulation across requests.
- **Tool struct with optional handler** -- `%Tool{}` has `name`, `description`, `input_schema`, and `handler`. The handler is local metadata (like message timestamps) -- ignored by dialects, used for tool execution by the caller's application code.
- **`input_schema` over `parameters`** -- consistent with `ToolUse.input` (tool defines `input_schema`, model returns `input` conforming to it). Avoids OpenAI's nested `function.parameters` baggage.
- **JSON Schema maps for tool schemas** -- `input_schema` holds a standard JSON Schema map, the universal wire format all providers accept. `Omni.Tool.Schema` provides plain builder functions (`object`, `string`, `number`, `enum`, etc.) as an ergonomic layer, but raw maps work directly.
- **Tool modules via `use Omni.Tool`** -- a behaviour with `input_schema/0`, `init/1`, and `call/1,2` callbacks. Name and description are passed as arguments to `use` (static configuration, not behaviour). The macro generates `new/0` and `new/1` constructors that produce `%Tool{}` structs with the handler wired automatically.
- **Stateful tools via `init/1`** -- `init/1` receives args passed to `new/1`, returns opts passed as second argument to `call/2`. Default is passthrough. Provides a place to validate state at construction time rather than mid-conversation. Stateless tools use `call/1` (default `call/2` delegates to it).
- **No automatic tool execution** -- `generate_text` and `stream_text` do not execute tools. They are pure request/response functions. `Omni.Tool.execute/2` is a convenience helper for dispatching tool uses to handlers.
- **Caching as a TTL hint, not an on/off switch** -- `cache: :short | :long | nil` controls explicit caching directives. `nil` means no explicit directives (providers with implicit caching may still cache). `:short` and `:long` map to provider-specific TTL tiers (e.g. Anthropic's 5min/1hr breakpoints, OpenAI's retention parameter). Dialects without caching support silently ignore the option -- caching is an optimisation hint, not a semantic requirement.
- **Provider as authenticated HTTP layer** -- the provider is independently usable via `Omni.Provider.stream/4` to make authenticated streaming HTTP requests with a provider-native request body. This makes the provider layer testable without involving dialects. The dialect is a translation layer that sits between Omni's top-level API and the provider.
- **Dialect builds, provider adapts** -- the dialect produces the standard request body and URL path for an API family. The provider optionally adapts these for service-specific quirks via `adapt_body/2` and `adapt_event/1`. These are *adaptations* of the dialect's output, not alternatives to it. Most providers don't need either callback.
- **"Adapt" over "tweak" for provider callbacks** -- `adapt_body/2` and `adapt_event/1` communicate the purpose clearly: adapting standard dialect output to fit a specific provider's requirements. The dialect *builds*, the provider *adapts*.
- **Declarative option schemas over validation callbacks** -- each layer declares what options it accepts via `option_schema/0` (on both the Dialect and Provider behaviours). The orchestration merges these into one Peri schema and validates once, early. No separate validate callback; no defensive checking in individual callbacks.
- **Dialect output is not validated at runtime** -- the request body a dialect produces is internal library code, not user input. If it's malformed, that's a bug caught by tests, not a runtime validation concern.
- **`build_body/3` and `authenticate/2` return ok/error tuples** -- these are the two callbacks that can fail due to legitimate runtime conditions (unsupported content in context, missing API keys, unreachable vaults). All other callbacks return bare values because they either produce static data or perform deterministic transformations on already-validated inputs.
- **`use Omni.Provider` with id, dialect, and models_file** -- providers declare identity via `use Omni.Provider, id: :anthropic, dialect: Omni.Dialects.AnthropicMessages, models_file: "priv/models/anthropic.json"`. `:id` and `:dialect` are required; `:models_file` is optional. The macro generates `id/0` and `dialect/0` accessor functions.
- **`models_file` over `models` for the data path option** -- `:models_file` is a file path string; the `models/0` callback returns model structs. Distinct names prevent confusion between the data source and the data itself.
- **Provider `models/0` callback with default implementation** -- every provider has a `models/0` callback returning `[%Model{}]`. The default calls `Omni.Provider.load_models/1`, which reads the declared `:models_file` JSON and builds model structs. Custom providers override to return models from any source.
- **`load_models/1` over `load/1`** -- `Omni.Provider.load_models/1` is precise about what it loads and pairs naturally with the `models/0` callback.
- **Full module references on Model struct** -- `%Model{provider: Omni.Providers.Anthropic, dialect: Omni.Dialects.AnthropicMessages}` stores full modules, not shorthand atoms. The model is self-contained -- provider and dialect callbacks can be called directly from the struct with no runtime resolution.
- **Provider config uses full module names** -- `config :omni, providers: [Omni.Providers.Anthropic, Omni.Providers.OpenAI]` uses full module names in the config. It's a config file that changes rarely; brevity isn't worth the magic of atom-to-module inference.
- **Default provider set** -- if no `:providers` config is set, a sensible default set (Anthropic, OpenAI, etc.) is loaded so the library works out of the box.
- **Omni.Application for startup loading** -- an OTP Application module loads providers into `:persistent_term` at startup. The `start/2` callback calls `models/0` on each configured provider, builds model maps, and stores them. Returns a minimal supervisor with no children (just the OTP contract). This guarantees models are available before any user code runs, with no lazy loading races or forgotten init calls.
- **Provider `build_url/2` callback** -- providers implement `build_url/2` receiving the base URL and dialect-built path. Default is concatenation. Exists because some providers (Azure OpenAI) completely restructure the URL path.
- **Stream handler composed at stream_text level** -- `stream_text` builds a Req `:into` callback that captures the provider and dialect via closure. The handler runs SSE parsing, `provider.adapt_event/1`, and `dialect.parse_event/1` in sequence. This keeps StreamingResponse generic (it just receives delta tuples) and keeps `Omni.Provider.stream` independently usable (the caller supplies their own `:into` callback).
- **StreamingResponse is provider/dialect-agnostic** -- `StreamingResponse.new/1` takes a callback that starts a stream. It spawns a process, runs the callback, and its `Enumerable` implementation receives delta messages and accumulates them. It has no knowledge of providers, dialects, or HTTP.
- **Single merged opts keyword list** -- provider config, application config overrides, and call-time opts are merged into a single keyword list early in the pipeline. Each callback that receives opts pulls out what it needs. Priority: call-time > app config > provider defaults.
- **Provider.stream/4 signature** -- takes `(provider, path, body, opts)` where `opts` is a keyword list containing both Req options (like `into:`) and Omni options (like `api_key:`). No separate config argument.
- **Spawned process sends deltas to caller** -- the streaming process (spawned by `StreamingResponse.new/1`) runs the HTTP request and parses events. Each parsed delta is sent as a message to the caller process. The caller's `Enumerable.reduce/3` receives these messages via the monitor ref, accumulates them, and yields consumer events. Bidirectional monitors handle failure: caller death terminates the stream; stream crash becomes an error event.
- **Signature round-tripping is a dialect concern** -- `signature` fields on Text, Thinking, and ToolUse blocks are received from providers in responses and must be included by dialects when building request bodies for subsequent turns. The content block structs carry signatures transparently; dialects handle the round-trip logic.
