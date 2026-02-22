# Phase 5b Refactor — Callback Renames, Orchestration Restructure, Validation

**Status:** Phase A complete. Phases B and C ready for implementation.
**Last updated:** February 2026

This document covers a three-phase refactor of the callback naming, orchestration flow, and option validation in Omni. The refactor cleans up deferred design decisions from Phase 5 and prepares the architecture for future provider additions (Azure, Bedrock, etc.).

---

## Background and Motivation

After completing Phase 5 (top-level orchestration), several loose ends remain:

1. **No option validation.** User options are passed through unchecked. Typos like `temperture` silently do nothing.
2. **Orchestration lives on Provider.** `Provider.build_request/3` and `Provider.parse_event/2` compose dialect + provider logic, but this orchestration doesn't belong on the Provider module. It should be separated into a dedicated `Omni.Request` module — keeping Provider as a pure behaviour/utilities module while enabling granular unit testing of request building, validation, and event parsing.
3. **`adapt_event/1` runs pre-dialect.** The provider can mutate raw SSE JSON before the dialect sees it, but can't augment the parsed delta tuples. This blocks the OpenRouter `reasoning_details` use case where the provider needs to inject additional deltas post-parse.
4. **`build_body/3` returns `{:ok, map()}`** but never fails. With validation happening before `build_body`, the ok-tuple is ceremony.
5. **Callback names are inconsistent.** Dialect callbacks use `build_*` prefixes while provider adaptation uses `adapt_*`. Neither follows Elixir conventions strongly.
6. **Provider `option_schema/0` is unused.** No provider has ever defined provider-specific inference options. Config overrides (`api_key`, `base_url`, `headers`) are consistent across all providers and belong in the universal schema.
7. **No receive timeout.** Req defaults to 15 seconds, which is insufficient for LLMs (especially extended thinking models). Needs a first-class `:timeout` option with a generous default.

---

## Summary of Changes

### Phase A — Rename Callbacks + Simplify Signatures

Mechanical renames across the codebase. No logic changes.

**Dialect callbacks:**
- `build_path/1` → `handle_path/2` (added opts arg)
- `build_body/3` → `handle_body/3` (also changes return from `{:ok, map()}` to `map()`)
- `parse_event/1` → `handle_event/1`
- `option_schema/0` — unchanged

**Provider callbacks:**
- `adapt_body/2` → `modify_body/2`
- `adapt_event/1` — left unchanged in Phase A (replaced by `modify_events/2` in Phase B, since it changes both name and signature/position in the pipeline)

**Phase A scope:**

| Current | Phase A | Notes |
|---------|---------|-------|
| Dialect `build_path/1` | `handle_path/2` | Rename + added opts arg |
| Dialect `build_body/3` | `handle_body/3` | Rename + return `map()` instead of `{:ok, map()}` |
| Dialect `parse_event/1` | `handle_event/1` | Rename only |
| Provider `adapt_body/2` | `modify_body/2` | Rename only |
| Provider `adapt_event/1` | *(unchanged in A)* | Replaced in Phase B |
| Provider `option_schema/0` | *(removed)* | Never used |

**Also in Phase A:**
- Remove `option_schema/0` from Provider behaviour and `use` macro defaults
- Update all dialect implementations (4 dialects)
- Update all provider implementations (4 providers)
- Update `Provider.build_request/3` and `Provider.parse_event/2` (still on Provider in Phase A)
- Update all tests (unit, integration, live)
- Update `Omni.Dialect` behaviour module

### Phase B — Restructure Orchestration into Omni.Request

Introduce `Omni.Request` module to hold all orchestration logic. This replaces the previous plan of moving orchestration into private functions in `Omni` — a dedicated module enables granular unit testing of request building, config merging, and event parsing without requiring full HTTP round-trips.

**New module: `Omni.Request`**

Public functions (the request lifecycle):
- `build/3` — validates opts, builds request body, constructs authenticated `%Req.Request{}`
- `stream/3` — executes request, composes SSE + event pipeline, returns `StreamingResponse`

`@doc false` functions (exposed for testing):
- `validate/2` — config extraction, three-tier merge, returns unified opts map
- `parse_event/2` — `dialect.handle_event` + `provider.modify_events` composition

**What moves from Provider to Omni.Request:**
- `Provider.build_request/3` logic → `Request.build/3`
- `Provider.parse_event/2` logic → `Request.parse_event/2`
- `Provider.new_request/4` logic → absorbed into `Request.build/3`

**What stays on Provider:**
- Behaviour definition (callbacks)
- `use Omni.Provider` macro with defaults
- `resolve_auth/1` — generic utility
- `load/1` — model loading into persistent_term
- `load_models/2` — JSON → Model structs
- `builtin_providers/0` — registry

**Callback signature changes in Phase B:**

| Callback | Before | After |
|----------|--------|-------|
| `adapt_event/1` | `(map()) → map()` pre-dialect | **Removed** — replaced by `modify_events/2` |
| `modify_events/2` | *(new)* | `([{atom(), map()}], map()) → [{atom(), map()}]` post-dialect |
| `build_url/2` | `(base_url, path) → url` | `(path, opts) → url` where opts is the unified map |
| `authenticate/2` | `(req, keyword()) → {:ok, req}` | `(req, opts) → {:ok, req}` where opts is the unified map |

**`modify_events/2` details:**
- First arg: the dialect's parsed delta list (output of `handle_event/1`)
- Second arg: the original raw SSE event map (for context/inspection)
- Returns: potentially modified/augmented delta list
- Default: returns first arg unchanged (passthrough)
- Runs **after** `dialect.handle_event/1`, not before
- This is the inverse of the request side: dialect builds → provider modifies. On the response side: dialect handles → provider modifies.

**Pipeline change:**

Before (Phase A):
```
raw_event → provider.adapt_event(event) → dialect.handle_event(adapted) → deltas
```

After (Phase B):
```
raw_event → dialect.handle_event(event) → provider.modify_events(deltas, event) → deltas
```

**`build_url/2` signature change:**
- Before: `build_url(base_url, path)` — provider concatenates base URL + path
- After: `build_url(path, opts)` — provider receives path + unified opts map
- The opts map contains `base_url` (from three-tier merge) plus all other config and inference options
- This supports Azure-style URL construction where the URL depends on deployment names, API versions, etc.
- Default implementation: `opts.base_url <> path`

**`authenticate/2` signature change:**
- Before: receives keyword list with `:api_key` and `:auth_header` keys
- After: receives the same unified opts map as `build_url`
- The opts map contains `api_key` (from three-tier merge, unresolved), `auth_header`, `headers`, plus inference options
- The default implementation reads `opts.api_key` and `opts.auth_header`, ignoring the rest

**Unified opts map:**

All callbacks receive one map containing both config and inference options. Each callback reads the keys it needs and ignores the rest. This replaces the previous design of separate config and opts maps, eliminating `split_request_config` and `merge_config` as standalone functions — config extraction and merging happen inside `validate`.

```elixir
%{
  # Config (from three-tier merge)
  api_key: {:system, "ANTHROPIC_API_KEY"},
  base_url: "https://api.anthropic.com",
  auth_header: "x-api-key",
  headers: %{"anthropic-version" => "..."},

  # Framework
  plug: nil,

  # Inference (validated, with defaults — after Phase C)
  max_tokens: 4096,
  temperature: 1.0,
  timeout: 300_000,
  ...
}
```

Note: `api_key` in the unified map is the **unresolved** value (could be a string, `{:system, env}`, or MFA tuple). `authenticate/2` calls `resolve_auth/1` internally to resolve it. This matches the current pattern.

**`validate/2` — config extraction and three-tier merge:**

In Phase B, `validate` handles config extraction and three-tier merging. No schema validation yet — that's Phase C:

```elixir
@doc false
def validate(model, opts) do
  provider = model.provider

  # Pop framework keys (not schema-validated)
  {plug, opts} = Keyword.pop(opts, :plug)

  # Pop config keys (three-tier merged, not schema-validated)
  {api_key, opts} = Keyword.pop(opts, :api_key)
  {base_url, opts} = Keyword.pop(opts, :base_url)
  {headers, opts} = Keyword.pop(opts, :headers)

  # Three-tier merge: call-site > app config > provider default
  provider_config = provider.config()
  app_config = Application.get_env(:omni, provider, [])

  config = %{
    api_key: api_key || app_config[:api_key] || provider_config[:api_key],
    base_url: base_url || app_config[:base_url] || provider_config[:base_url],
    auth_header: provider_config[:auth_header] || "authorization",
    headers: merge_headers(provider_config[:headers], app_config[:headers], headers),
    plug: plug
  }

  # Combine into unified map
  {:ok, Map.merge(Map.new(opts), config)}
end
```

**`Request.build/3`:**

```elixir
@spec build(Model.t(), Context.t(), keyword()) ::
        {:ok, Req.Request.t()} | {:error, term()}
def build(model, context, opts) do
  with {:ok, opts} <- validate(model, opts) do
    {plug, opts} = Map.pop(opts, :plug)

    body = model.dialect.handle_body(model, context, opts)
    body = model.provider.modify_body(body, opts)
    path = model.dialect.handle_path(model, opts)
    url = model.provider.build_url(path, opts)

    req =
      Req.new(method: :post, url: url, json: body, into: :self)
      |> apply_headers(opts.headers)
      |> maybe_merge_plug(plug)

    model.provider.authenticate(req, opts)
  end
end
```

**`Request.stream/3`:**

```elixir
@spec stream(Req.Request.t(), Model.t(), keyword()) ::
        {:ok, StreamingResponse.t()} | {:error, term()}
def stream(req, model, opts \\ []) do
  raw? = Keyword.get(opts, :raw, false)

  with {:ok, resp} <- Req.request(req),
       :ok <- check_status(resp) do
    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.flat_map(&parse_event(model, &1))

    cancel = fn -> Req.cancel_async_response(resp) end
    raw = if raw?, do: {req, resp}

    {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
  end
end
```

**`Request.parse_event/2`:**

```elixir
@doc false
@spec parse_event(Model.t(), map()) :: [{atom(), map()}]
def parse_event(model, raw_event) do
  raw_event
  |> model.dialect.handle_event()
  |> model.provider.modify_events(raw_event)
end
```

**`Omni.stream_text/3` after Phase B:**

```elixir
def stream_text(%Model{} = model, context, opts) do
  context = Context.new(context)
  {raw, opts} = Keyword.pop(opts, :raw, false)

  with {:ok, req} <- Request.build(model, context, opts) do
    Request.stream(req, model, raw: raw)
  end
end
```

**What to do about existing tests:**

- `Provider.build_request/3`, `parse_event/2`, `new_request/4` tests → migrate to test `Request.build/3`, `Request.parse_event/2`, and `Request.validate/2`
- Dialect unit tests (handle_body, handle_event) remain unchanged
- Provider unit tests for `modify_body` and `modify_events` remain unchanged
- Integration tests already go through `Omni.generate_text/3` and `Omni.stream_text/3` — they continue to work
- New unit tests for `Request.validate/2`: config extraction, three-tier merge, unified map structure
- New unit tests for `Request.build/3`: inspect `%Req.Request{}` (URL, body, headers, auth) without executing
- New unit tests for `Request.parse_event/2`: event pipeline composition

### Phase C — Option Validation + Timeout

Add the universal option schema with Peri validation, a `:timeout` option, and switch opts from keyword list to validated map.

**Universal option schema** — defined as a module attribute on `Omni.Request`:

```elixir
@schema %{
  max_tokens: {:required, {:integer, {:default, 4096}}},
  temperature: {:float, {:default, 1.0}},
  timeout: {:integer, {:default, 300_000}},
  cache: {:enum, [:short, :long]},
  metadata: :map,
  thinking: :any  # complex type — may need custom validator
}
```

Note: The exact Peri syntax will need to be verified against Peri's documentation. The schema above is illustrative. Key points:
- `max_tokens` has a default of 4096
- `temperature` has a default of 1.0
- `timeout` defaults to 300,000ms (5 minutes) — maps to Req's `receive_timeout`. This is generous enough for extended thinking models that may not send keepalives during long reasoning phases. Req's default of 15s is far too low for LLM APIs.
- `cache`, `metadata`, `thinking` are optional (nil if not provided)
- `thinking` accepts: `true | false | :none | :low | :medium | :high | :max | [effort: atom, budget: integer]` — this may need a custom validator

**Schema merging** — `Request.validate` merges the universal schema with the dialect's `option_schema/0`:

```elixir
schema = Map.merge(@schema, dialect.option_schema())
```

Provider no longer contributes an option schema (removed in Phase A). If a provider needs a provider-specific inference option in the future, we can re-add it.

**Updated `validate/2` after Phase C:**

```elixir
@doc false
def validate(model, opts) do
  provider = model.provider
  dialect = provider.dialect()

  # Pop framework keys (not schema-validated)
  {plug, opts} = Keyword.pop(opts, :plug)

  # Pop config keys (three-tier merged, not schema-validated)
  {api_key, opts} = Keyword.pop(opts, :api_key)
  {base_url, opts} = Keyword.pop(opts, :base_url)
  {headers, opts} = Keyword.pop(opts, :headers)

  # Validate inference opts — strict mode catches typos
  schema = Map.merge(@schema, dialect.option_schema())

  with {:ok, opts} <- Peri.validate(schema, Map.new(opts)) do
    # Three-tier merge config values
    provider_config = provider.config()
    app_config = Application.get_env(:omni, provider, [])

    config = %{
      api_key: api_key || app_config[:api_key] || provider_config[:api_key],
      base_url: base_url || app_config[:base_url] || provider_config[:base_url],
      auth_header: provider_config[:auth_header] || "authorization",
      headers: merge_headers(provider_config[:headers], app_config[:headers], headers),
      plug: plug
    }

    {:ok, Map.merge(opts, config)}
  end
end
```

**How typos are caught:**

Config keys, framework keys, and `:raw` are all popped before Peri strict validation. If any of these are misspelled (e.g. `api_kye`, `plg`, `rraw`), they won't be popped and will pass through to strict schema validation, which rejects unknown keys. Inference key typos (e.g. `temperture`) are caught directly by strict validation.

**`:timeout` flows through to `build`:**

After Phase C, `build` pops `:timeout` from the validated map and applies it to the Req request:

```elixir
def build(model, context, opts) do
  with {:ok, opts} <- validate(model, opts) do
    {plug, opts} = Map.pop(opts, :plug)
    {timeout, opts} = Map.pop(opts, :timeout)

    body = model.dialect.handle_body(model, context, opts)
    body = model.provider.modify_body(body, opts)
    path = model.dialect.handle_path(model, opts)
    url = model.provider.build_url(path, opts)

    req =
      Req.new(method: :post, url: url, json: body, into: :self, receive_timeout: timeout)
      |> apply_headers(opts.headers)
      |> maybe_merge_plug(plug)

    model.provider.authenticate(req, opts)
  end
end
```

**No `:req_opts` escape hatch.** Arbitrary Req options (proxies, custom Finch pools, SSL config) are infrastructure concerns best handled at the Finch pool level, not per-request. Adding `:req_opts` later is a single non-breaking addition if needed — pop it in `build`, `Req.merge(req, req_opts)` before returning.

**Downstream impact — opts becomes a map:**

All callbacks that receive opts already receive a map (since `validate` returns a map in Phase B). The change in Phase C is that the map now has validated types and defaults filled in:
- `dialect.handle_body(model, context, opts)` — opts is `%{max_tokens: 4096, ...}`
- `provider.modify_body(body, opts)` — same
- `provider.build_url(path, opts)` — same unified map
- `provider.authenticate(req, opts)` — same unified map
- Every `Keyword.get(opts, :key, default)` becomes `opts[:key]` or `opts.key` or `Map.get(opts, :key)`

This affects all 4 dialect `handle_body` implementations and any provider `modify_body` that reads opts.

**Updated full flow after Phase C:**

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
│     ├── provider.modify_body(body, opts) → modified body
│     ├── dialect.handle_path(model, opts) → path
│     ├── provider.build_url(path, opts) → URL
│     ├── Req.new(url, method: :post, json: body, into: :self, receive_timeout: timeout)
│     ├── apply_headers(req, opts.headers) + maybe_merge_plug(plug)
│     └── provider.authenticate(req, opts) → {:ok, req}
├── 5. Request.stream(req, model, raw: raw)
│     ├── Req.request(req) → {:ok, resp}
│     ├── check_status(resp) → :ok | {:error, ...}
│     ├── SSE.stream(resp.body)
│     ├── Stream.flat_map: Request.parse_event(model, event)
│     │     ├── dialect.handle_event(event) → deltas
│     │     └── provider.modify_events(deltas, event) → deltas
│     └── StreamingResponse.new(stream, model: model, cancel: cancel, raw: raw)
└── Return {:ok, StreamingResponse.t()} | {:error, term()}
```

---

## Files Affected

### Phase A (renames)

**Behaviour definitions:**
- `lib/omni/dialect.ex` — rename callback specs
- `lib/omni/provider.ex` — rename callback specs, remove `option_schema/0`, update `build_request/3` and `parse_event/2` callers

**Dialect implementations (4 files):**
- `lib/omni/dialects/anthropic_messages.ex`
- `lib/omni/dialects/openai_responses.ex`
- `lib/omni/dialects/openai_completions.ex`
- `lib/omni/dialects/google_gemini.ex`

Each needs:
- `build_path/1` → `handle_path/2` (added opts arg)
- `build_body/3` → `handle_body/3` + remove `{:ok, ...}` wrapper from return
- `parse_event/1` → `handle_event/1`

**Provider implementations (4 files):**
- `lib/omni/providers/anthropic.ex`
- `lib/omni/providers/openai.ex`
- `lib/omni/providers/google.ex`
- `lib/omni/providers/openrouter.ex`

Each needs:
- `adapt_body/2` → `modify_body/2` (OpenRouter only — others use default)
- Remove `option_schema/0` override if present

**Orchestration:**
- `lib/omni.ex` — update the `with` clause that unwraps `{:ok, body}` from `build_body` (no longer needed since `handle_body` returns bare map)

**Tests (many files):**
- `test/omni/provider_test.exs` — rename references
- `test/omni/dialects/anthropic_messages_test.exs` — `build_body` → `handle_body`, `parse_event` → `handle_event`, update `{:ok, body}` assertions to bare map
- `test/omni/dialects/openai_responses_test.exs` — same
- `test/omni/dialects/openai_completions_test.exs` — same
- `test/omni/dialects/google_gemini_test.exs` — same
- Integration and live tests should not need changes (they go through `Omni.generate_text/3`)

### Phase B (orchestration restructure)

**New module:**
- `lib/omni/request.ex` — `Omni.Request` with `build/3`, `stream/3`, `validate/2`, `parse_event/2`

**Provider module:**
- `lib/omni/provider.ex` — remove `build_request/3`, `parse_event/2`, `new_request/4`. Add `modify_events/2` to behaviour. Remove `adapt_event/1` from behaviour. Change `build_url/2` and `authenticate/2` signatures (parameter is now the unified opts map).

**Omni module:**
- `lib/omni.ex` — simplify `stream_text/3` to delegate to `Request.build/3` and `Request.stream/3`. Remove private helpers that move to Request (`check_status`, error body reading, `maybe_merge_plug`, `apply_headers`).

**Provider implementations:**
- `lib/omni/providers/openai.ex` — update `authenticate/2` to work with unified opts map
- `lib/omni/providers/openrouter.ex` — update `authenticate/2` to work with unified opts map
- All providers: update `build_url/2` signature (most use default, but need to update the default in `use` macro)
- All providers: remove `adapt_event/1` override if any, add `modify_events/2` if needed

**Tests:**
- `test/omni/provider_test.exs` — remove tests for `build_request/3`, `parse_event/2`, `new_request/4`. Update callback tests for new signatures.
- `test/omni/request_test.exs` — new unit tests for `validate/2` (config merging, three-tier resolution), `build/3` (request inspection), `parse_event/2` (event pipeline)
- Integration tests should continue passing (same top-level API)

### Phase C (validation)

**Request module:**
- `lib/omni/request.ex` — add `@schema` module attribute, Peri validation inside `validate/2`, `:timeout` handling in `build/3`

**Dialect implementations (4 files):**
- All `handle_body/3` implementations: change `Keyword.get(opts, :key)` → `opts[:key]` or `opts.key` or `Map.get(opts, :key)` (if not already done in Phase B)

**Provider implementations:**
- `lib/omni/providers/openrouter.ex` — update `modify_body/2` if it reads opts

**Dialect option schemas (4 files):**
- Define actual Peri schemas in `option_schema/0` for dialect-specific options (e.g. Anthropic's thinking budget constraints)

**Tests:**
- Add validation tests in `test/omni/request_test.exs` (unknown keys rejected, defaults applied, type errors, timeout default)
- Update any tests that construct opts as keyword lists where the validated map is expected

---

## Callback Reference (Final State)

### Dialect Behaviour

```elixir
defmodule Omni.Dialect do
  @doc "Returns a Peri schema for dialect-specific options."
  @callback option_schema() :: map()

  @doc "Returns the URL path for the given model."
  @callback handle_path(Model.t(), keyword()) :: String.t()

  @doc "Builds the request body from the model, context, and validated options."
  @callback handle_body(Model.t(), Context.t(), map()) :: map()

  @doc "Parses a raw SSE event into a list of delta tuples."
  @callback handle_event(map()) :: [{atom(), map()}]
end
```

### Provider Behaviour

```elixir
defmodule Omni.Provider do
  @doc "Returns the provider's base configuration."
  @callback config() :: map()

  @doc "Returns the provider's list of model structs."
  @callback models() :: [Model.t()]

  @doc "Builds the full request URL from a path and the unified opts map."
  @callback build_url(path :: String.t(), opts :: map()) :: String.t()

  @doc "Adds authentication to a Req request."
  @callback authenticate(Req.Request.t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc "Modifies the dialect-built request body for this provider."
  @callback modify_body(body :: map(), opts :: map()) :: map()

  @doc "Modifies dialect-parsed deltas for this provider."
  @callback modify_events([{atom(), map()}], raw_event :: map()) :: [{atom(), map()}]
end
```

### Provider `use` Macro Defaults

```elixir
defmacro __using__(opts) do
  dialect = Keyword.fetch!(opts, :dialect)

  quote do
    @behaviour Omni.Provider

    @doc false
    def dialect, do: unquote(dialect)

    @impl Omni.Provider
    def models, do: []

    @impl Omni.Provider
    def build_url(path, opts), do: opts.base_url <> path

    @impl Omni.Provider
    def authenticate(req, opts) do
      with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
        header = Map.get(opts, :auth_header, "authorization")
        {:ok, Req.Request.put_header(req, header, key)}
      end
    end

    @impl Omni.Provider
    def modify_body(body, _opts), do: body

    @impl Omni.Provider
    def modify_events(deltas, _raw_event), do: deltas

    defoverridable models: 0,
                   build_url: 2,
                   authenticate: 2,
                   modify_body: 2,
                   modify_events: 2
  end
end
```

---

## Design Decisions Made

1. **Orchestration in `Omni.Request`, not private functions in `Omni`.** A dedicated module enables unit testing of request building, validation, and event parsing in isolation. `Omni` stays as a thin public API layer. `Request.validate/2` and `Request.parse_event/2` are `@doc false` but public for testability.
2. **Unified opts map, not separate config and inference maps.** All callbacks receive one map containing config, framework, and inference options. Each callback reads the keys it needs and ignores the rest. This eliminates the need for `split_request_config` and `merge_config` as separate functions — config extraction and merging happen inside `validate`.
3. **Config keys bypass schema validation.** `validate` pops config keys (`api_key`, `base_url`, `headers`) and framework keys (`plug`) before Peri strict validation. This means: (a) config keys don't need complex union types in the schema, (b) typos in config keys are caught because the misspelled key passes through to strict validation and is rejected as unknown.
4. **`:timeout` as a first-class option.** Defaults to 300,000ms (5 minutes). Maps to Req's `receive_timeout`. LLM APIs routinely exceed Req's default 15s, especially extended thinking models. Proxies and other Req options are deferred — YAGNI, and a `:req_opts` escape hatch is trivial to add later if needed.
5. **Validation at the API boundary, not in callbacks.** `build` calls `validate` once. Callbacks receive known-good data.
6. **Universal schema on `Omni.Request`, not `Omni`.** Co-located with the validation logic that uses it.
7. **No provider option_schema.** Config overrides are consistent across providers (universal). Re-add if a genuine provider-specific inference option appears.
8. **Post-dialect `modify_events` replaces pre-dialect `adapt_event`.** Provider sees parsed deltas + raw event, can augment/modify. Mirrors request side (dialect builds, provider modifies).
9. **`build_url` and `authenticate` receive the unified opts map.** No separate config map. Supports Azure-style URL construction where the URL depends on deployment names, API versions, etc. Simpler plumbing — one map flows through everything.
10. **`handle_body` returns bare `map()`.** Validation catches errors before the dialect runs. The ok-tuple wrapper added no value.
11. **Opts become a map after validation.** Peri returns a map with defaults filled in. All downstream code works with maps.
12. **Strict validation (reject unknown keys).** Catches typos like `temperture`.
13. **`handle_*` for dialect, `modify_*` for provider.** Dialect callbacks are mandatory handlers. Provider callbacks are optional modifiers. The naming reflects the distinction.
14. **No `handle_params` — using `handle_body` instead.** `handle_params` collides with Phoenix LiveView's callback. `handle_body` is clear and maintains symmetry with `modify_body`.
15. **Headers merge, not overwrite.** Three-tier: provider config → app config → call-site, each layer merged on top. `Map.merge/2` with later layers winning on key collision.
