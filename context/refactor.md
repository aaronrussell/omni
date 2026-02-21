# Phase 5b Refactor — Callback Renames, Orchestration Restructure, Validation

**Status:** Ready for implementation
**Last updated:** February 2026

This document covers a three-phase refactor of the callback naming, orchestration flow, and option validation in Omni. The refactor cleans up deferred design decisions from Phase 5 and prepares the architecture for future provider additions (Azure, Bedrock, etc.).

---

## Background and Motivation

After completing Phase 5 (top-level orchestration), several loose ends remain:

1. **No option validation.** User options are passed through unchecked. Typos like `temperture` silently do nothing.
2. **Orchestration lives on Provider.** `Provider.build_request/3` and `Provider.parse_event/2` compose dialect + provider logic, but this orchestration belongs in the top-level `Omni` module since that's where config merging, validation, and the full pipeline live.
3. **`adapt_event/1` runs pre-dialect.** The provider can mutate raw SSE JSON before the dialect sees it, but can't augment the parsed delta tuples. This blocks the OpenRouter `reasoning_details` use case where the provider needs to inject additional deltas post-parse.
4. **`build_body/3` returns `{:ok, map()}`** but never fails. With validation happening before `build_body`, the ok-tuple is ceremony.
5. **Callback names are inconsistent.** Dialect callbacks use `build_*` prefixes while provider adaptation uses `adapt_*`. Neither follows Elixir conventions strongly.
6. **Provider `option_schema/0` is unused.** No provider has ever defined provider-specific inference options. Config overrides (`api_key`, `base_url`, `headers`) are consistent across all providers and belong in the universal schema.

---

## Summary of Changes

### Phase A — Rename Callbacks + Simplify Signatures

Mechanical renames across the codebase. No logic changes.

**Dialect callbacks:**
- `build_path/1` → `handle_path/1`
- `build_body/3` → `handle_body/3` (also changes return from `{:ok, map()}` to `map()`)
- `parse_event/1` → `handle_event/1`
- `option_schema/0` — unchanged

**Provider callbacks:**
- `adapt_body/2` → `modify_body/2`
- `adapt_event/1` — left unchanged in Phase A (replaced by `modify_events/2` in Phase B, since it changes both name and signature/position in the pipeline)

**Phase A scope:**

| Current | Phase A | Notes |
|---------|---------|-------|
| Dialect `build_path/1` | `handle_path/1` | Rename only |
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

### Phase B — Restructure Orchestration

Move orchestration from `Provider` into `Omni`. Change `adapt_event` to post-dialect `modify_events`. Update `build_url` and `authenticate` signatures.

**What moves from Provider to Omni:**
- `Provider.build_request/3` logic → private function(s) in `Omni`
- `Provider.parse_event/2` logic → inlined in `Omni.stream_text/3` pipeline
- `Provider.new_request/4` logic → private function in `Omni`

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
| `build_url/2` | `(base_url, path) → url` | `(path, config) → url` where config is the merged config map |
| `authenticate/2` | `(req, keyword()) → {:ok, req}` | `(req, map()) → {:ok, req}` where map is the merged config |

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
- After: `build_url(path, config)` — provider receives path + full merged config map
- The config map contains `base_url` (from three-tier merge) plus all other config
- This supports Azure-style URL construction where the URL depends on deployment names, API versions, etc.
- Default implementation: `config.base_url <> path`

**`authenticate/2` signature change:**
- Before: receives keyword list with `:api_key` and `:auth_header` keys
- After: receives the same merged config map as `build_url`
- The config map contains `api_key` (already resolved via three-tier), `auth_header`, `headers`, etc.

**The merged config map** (passed to `build_url`, `authenticate`, and available in the orchestration):
```elixir
%{
  base_url: "https://api.anthropic.com",   # from three-tier merge
  api_key: {:system, "ANTHROPIC_API_KEY"},  # from three-tier merge (unresolved)
  auth_header: "x-api-key",                # from provider config
  headers: %{"anthropic-version" => "..."}  # from three-tier merge
}
```

Note: `api_key` in the config map is the **unresolved** value (could be a string, `{:system, env}`, or MFA tuple). `authenticate/2` calls `resolve_auth/1` internally to resolve it. This matches the current pattern where `new_request/4` passes the unresolved value and `authenticate/2` resolves it.

**New `Omni.stream_text/3` flow after Phase B:**
```elixir
def stream_text(%Model{} = model, context, opts) do
  provider = model.provider
  dialect = model.dialect
  context = Context.new(context)
  {request_config, opts} = split_request_config(opts)

  # Build request body (dialect builds, provider modifies)
  body = dialect.handle_body(model, context, opts)
  body = provider.modify_body(body, opts)

  # Build HTTP request
  path = dialect.handle_path(model)
  config = merge_config(provider, request_config)

  with {:ok, req} <- build_request(provider, path, body, config),
       {:ok, resp} <- req |> maybe_plug(request_config) |> Req.request(),
       :ok <- check_status(resp) do
    # Compose event stream (dialect handles, provider modifies)
    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.flat_map(fn event ->
        event
        |> dialect.handle_event()
        |> provider.modify_events(event)
      end)

    cancel = fn -> Req.cancel_async_response(resp) end
    raw = if request_config[:raw], do: {req, resp}

    {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
  end
end
```

Where `build_request/4` is a private function in Omni:
```elixir
defp build_request(provider, path, body, config) do
  url = provider.build_url(path, config)

  req =
    Req.new(method: :post, url: url, json: body, into: :self)
    |> apply_headers(config.headers)

  provider.authenticate(req, config)
end
```

And `merge_config/2` implements three-tier resolution:
```elixir
defp merge_config(provider, request_config) do
  provider_config = provider.config()
  app_config = Application.get_env(:omni, provider, [])

  %{
    base_url: request_config[:base_url] || app_config[:base_url] || provider_config[:base_url],
    api_key: request_config[:api_key] || app_config[:api_key] || provider_config[:api_key],
    auth_header: provider_config[:auth_header] || "authorization",
    headers: merge_headers(provider_config[:headers], app_config[:headers], request_config[:headers])
  }
end
```

**`split_request_config/1`** separates transport/framework options from inference options:
```elixir
defp split_request_config(opts) do
  {api_key, opts} = Keyword.pop(opts, :api_key)
  {base_url, opts} = Keyword.pop(opts, :base_url)
  {headers, opts} = Keyword.pop(opts, :headers)
  {plug, opts} = Keyword.pop(opts, :plug)
  {raw, opts} = Keyword.pop(opts, :raw, false)

  config = %{api_key: api_key, base_url: base_url, headers: headers, plug: plug, raw: raw}
  {config, opts}
end
```

**What to do about tests that currently test Provider.build_request/3 and Provider.parse_event/2:**
- These test the composition of dialect + provider. After the move, this composition lives in `Omni.stream_text/3`.
- Dialect unit tests (handle_body, handle_event) remain unchanged.
- Provider unit tests for `modify_body` and `modify_events` remain unchanged.
- Integration tests already go through `Omni.generate_text/3` and `Omni.stream_text/3`, so they cover the composition.
- Remove `Provider.build_request/3`, `Provider.parse_event/2`, and `Provider.new_request/4` from Provider module.
- Remove or migrate any unit tests that directly tested these functions. The `parse_event/2` test in `provider_test.exs` that tested the adapt→parse composition can be removed since integration tests cover it. The `new_request/4` tests that verified auth resolution, header merging, and URL construction should be migrated to test the new private helper (or kept as integration tests).

### Phase C — Option Validation + Config Merging

Add the universal option schema, Peri validation, and switch opts from keyword list to validated map.

**Universal option schema** — defined as a module attribute in `Omni`:
```elixir
@universal_schema %{
  max_tokens: {:required, {:integer, {:default, 4096}}},
  temperature: {:float, {:default, 1.0}},
  cache: {:enum, [:short, :long]},
  metadata: :map,
  thinking: :any  # complex type — validated structurally below
}
```

Note: The exact Peri syntax will need to be verified against Peri's documentation. The schema above is illustrative. Key points:
- `max_tokens` has a default of 4096
- `temperature` has a default (provider-dependent? or fixed?)
- `cache`, `metadata`, `thinking` are optional (nil if not provided)
- `thinking` accepts: `true | false | :none | :low | :medium | :high | :max | [effort: atom, budget: integer]` — this may need a custom validator

**Schema merging** — `Omni` merges the universal schema with the dialect's `option_schema/0`:
```elixir
defp build_schema(dialect) do
  Map.merge(@universal_schema, dialect.option_schema())
end
```

Provider no longer contributes an option schema (removed in Phase A). If a provider needs a provider-specific inference option in the future, we can re-add it.

**Validation call:**
```elixir
with {:ok, opts} <- validate_opts(build_schema(dialect), inference_opts) do
  # opts is now a map with all defaults filled in
  # e.g. %{max_tokens: 4096, temperature: 1.0, cache: nil, ...}
end
```

Using `Peri.validate(schema, opts)` in strict mode (default). This:
- Validates types for all provided options
- Fills in defaults for missing options
- Rejects unknown keys (catches typos)
- Returns a map (not a keyword list)

**Downstream impact — opts becomes a map:**

All callbacks that receive opts need to handle a map instead of a keyword list:
- `dialect.handle_body(model, context, opts)` — opts is now `%{max_tokens: 4096, ...}`
- `provider.modify_body(body, opts)` — same
- Every `Keyword.get(opts, :key, default)` becomes `Map.get(opts, :key, default)` or `opts.key` or `opts[:key]`

This affects all 4 dialect `handle_body` implementations and any provider `modify_body` that reads opts.

**Three-tier config merge for base_url and headers:**

Extending the existing three-tier pattern (call-site > app config > provider default) from just `api_key` to also cover `base_url` and `headers`. This was partially implemented in Phase B's `merge_config/2` — Phase C ensures it works end-to-end with validated options.

**Updated full flow after Phase C:**
```
Omni.stream_text(model, context, opts)
├── 1. Resolve model ({provider, id} tuple → %Model{})
├── 2. Coerce context (string/list → %Context{})
├── 3. Split opts → request_config (map) + inference_opts (keyword)
├── 4. Validate inference_opts → opts (map with defaults)
│     Schema = universal + dialect.option_schema()
│     Peri.validate in strict mode
│     Result: %{max_tokens: 4096, temperature: 1.0, ...}
├── 5. Build request body
│     ├── dialect.handle_body(model, context, opts) → map()
│     └── provider.modify_body(body, opts) → map()
├── 6. Build HTTP request
│     ├── dialect.handle_path(model) → path
│     ├── merge_config(provider, request_config) → config map
│     ├── provider.build_url(path, config) → url
│     ├── Req.new(method: :post, url: url, json: body, into: :self)
│     ├── apply_headers(req, config.headers)
│     └── provider.authenticate(req, config) → {:ok, req}
├── 7. Execute: Req.request(req)
├── 8. Check HTTP status (200 ok, else error)
├── 9. Compose event stream
│     ├── SSE.stream(resp.body)
│     └── Stream.flat_map: dialect.handle_event → provider.modify_events
└── 10. StreamingResponse.new(stream, model: model, cancel: cancel, raw: raw)
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
- `build_path/1` → `handle_path/1`
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

**Provider module:**
- `lib/omni/provider.ex` — remove `build_request/3`, `parse_event/2`, `new_request/4`. Add `modify_events/2` to behaviour. Remove `adapt_event/1` from behaviour. Change `build_url/2` and `authenticate/2` signatures.

**Omni module:**
- `lib/omni.ex` — add private orchestration functions: `build_request/4`, `merge_config/2`, `split_request_config/1`, `apply_headers/2`. Rewrite `stream_text/3` to inline the orchestration.

**Provider implementations:**
- `lib/omni/providers/openai.ex` — update `authenticate/2` to work with config map
- `lib/omni/providers/openrouter.ex` — update `authenticate/2` to work with config map
- All providers: update `build_url/2` signature (most use default, but need to update the default in `use` macro)
- All providers: remove `adapt_event/1` override if any, add `modify_events/2` if needed

**Tests:**
- `test/omni/provider_test.exs` — remove tests for `build_request/3`, `parse_event/2`, `new_request/4`. Update callback tests for new signatures.
- Integration tests should continue passing (same top-level API)

### Phase C (validation)

**Omni module:**
- `lib/omni.ex` — add `@universal_schema`, `build_schema/1`, `validate_opts/2`. Update `stream_text/3` to validate before building.

**Dialect implementations (4 files):**
- All `handle_body/3` implementations: change `Keyword.get(opts, :key)` → `opts[:key]` or `opts.key` or `Map.get(opts, :key)`

**Provider implementations:**
- `lib/omni/providers/openrouter.ex` — update `modify_body/2` if it reads opts

**Dialect option schemas (4 files):**
- Define actual Peri schemas in `option_schema/0` for dialect-specific options (e.g. Anthropic's thinking budget constraints)

**Tests:**
- Add validation tests (unknown keys rejected, defaults applied, type errors)
- Update any tests that construct opts as keyword lists where the validated map is expected

---

## Callback Reference (Final State)

### Dialect Behaviour

```elixir
defmodule Omni.Dialect do
  @doc "Returns a Peri schema for dialect-specific options."
  @callback option_schema() :: map()

  @doc "Returns the URL path for the given model."
  @callback handle_path(Model.t()) :: String.t()

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

  @doc "Builds the full request URL from a path and merged config."
  @callback build_url(path :: String.t(), config :: map()) :: String.t()

  @doc "Adds authentication to a Req request."
  @callback authenticate(Req.Request.t(), config :: map()) ::
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
    def build_url(path, config), do: config.base_url <> path

    @impl Omni.Provider
    def authenticate(req, config) do
      with {:ok, key} <- Omni.Provider.resolve_auth(config.api_key) do
        header = Map.get(config, :auth_header, "authorization")
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

1. **Validation at the API boundary, not in callbacks.** `stream_text` validates once. Callbacks receive known-good data.
2. **Universal schema in Omni, not a separate module.** Module attribute keeps it co-located with the orchestration that uses it.
3. **No provider option_schema.** Config overrides are consistent across providers (universal). Re-add if a genuine provider-specific inference option appears.
4. **Post-dialect `modify_events` replaces pre-dialect `adapt_event`.** Provider sees parsed deltas + raw event, can augment/modify. Mirrors request side (dialect builds, provider modifies).
5. **`build_url` receives config map, not just base_url.** Supports Azure-style URL construction where URLs depend on deployment names, API versions, etc.
6. **`authenticate` receives config map, not keyword list.** Consistency with `build_url`. Both get the same merged config.
7. **`handle_body` returns bare `map()`.** Validation catches errors before the dialect runs. The ok-tuple wrapper added no value.
8. **Opts become a map after validation.** Peri returns a map with defaults filled in. All downstream code works with maps.
9. **Strict validation (no permissive mode).** Unknown keys are filtered out. Catches typos like `temperture`.
10. **`handle_*` for dialect, `modify_*` for provider.** Dialect callbacks are mandatory handlers. Provider callbacks are optional modifiers. The naming reflects the distinction.
11. **No `handle_params` — using `handle_body` instead.** `handle_params` collides with Phoenix LiveView's callback. `handle_body` is clear and maintains symmetry with `modify_body`.
12. **Headers merge, not overwrite.** Three-tier: provider config → app config → call-site, each layer merged on top. `Map.merge/2` with later layers winning on key collision.
