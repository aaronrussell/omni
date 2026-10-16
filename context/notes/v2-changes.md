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

**`base_url` includes the API version segment.** *(phase 1)* `"https://api.openai.com/v1"`, `"https://generativelanguage.googleapis.com/v1beta"`, `"https://api.z.ai/api/paas/v4"`. Dialect paths are resource paths only (`/chat/completions`). Any configured `base_url` needs updating. Local Ollama is unchanged (`http://localhost:11434`, path `/api/chat`).

**`auth_header:` is replaced by `auth:`.** *(phase 1)* `auth_header: "x-api-key"` becomes `auth: {:header, "x-api-key"}`. Values: `:bearer`, `{:header, name}`, `:none`, `:dialect` (the default — the scheme of the dialect's home API). Using `auth_header:` raises with a hint.

**Per-provider source override moved.** *(phase 1)* `config :omni, Omni.Providers.OpenAI, source: ...` becomes `config :omni, :providers, openai: [source: ...]`.

**Unknown keys are errors.** *(phase 1)* Per-provider keys: `name, base_url, api_key, auth, headers, dialects, module, models, source`. `:models` keys: `providers, source, filter`. Entries for providers that aren't loaded are still validated.

**The legacy v1.x `:providers` list** (`config :omni, :providers, [:anthropic, :openai]`) still raises, with an updated message.

## Providers

**Providers are data.** *(phase 1)* A provider is an `%Omni.Provider{}` struct (`id, name, base_url, api_key, auth, headers, dialects, module, tier`), assembled at load from source catalog data, then an optional provider module's `config/0`, then app config. Values replace; `headers` merge by key, `dialects` by capability, `models` by id.

**Any catalog provider loads by id.** *(phase 1)* For example `providers: [:builtins, :togetherai]`, with `togetherai: [base_url: "https://api.together.xyz/v1"]` where the catalog lacks a base URL. These are `tier: :catalog` — they speak their dialect plain, with no quirks.

**Custom providers need only config.** *(phase 1)*

```elixir
config :omni, :providers,
  gpu_box: [
    base_url: "http://gpu-box:8000/v1",
    dialects: %{text: Omni.Dialects.OpenAICompletions},
    auth: :none,
    models: ["llama-3.3-70b", [id: "qwen3-32b", context_size: 32_768]]
  ]
```

**One id per provider, no renaming.** *(phase 1)* The id is the catalog key snake_cased; it is used for config, lookups and catalog lookups. The `provider_id:` source option is gone. Two instances of one provider aren't supported — use call-site `base_url:` and `api_key:` for a second region or key.

**Provider modules changed shape.** *(phase 1)*
- `use Omni.Provider, id: ..., dialect: ...` is gone; modules declare `@behaviour Omni.Provider` and carry no id.
- Attach a custom module with `module:` in the provider's config entry.
- All callbacks are optional: `config/0` (a keyword list of overrides), `models/2` (models plus the merged provider), and the provisional `modify_request/3`, `modify_body/4`, `modify_deltas/3`.
- Removed: `build_url/2`, `authenticate/2`, `modify_events/2`, `models/0`, `id/0`, `dialect/0`.
- Removed from `Omni.Provider`: `load_models/2`, `providers_from_config/1`, `build_model/2` (now `Omni.Source.build_model/1`).

**`Omni.Provider.load/1` takes ids**, or `{id, opts}` with inline config; reloading an id replaces its provider and models. *(phase 1)*

**New: `Omni.get_provider/1`.** *(phase 1)*

**Local Ollama sends no credentials** (`auth: :none`). *(phase 1)* In v1 a configured key was sent as a Bearer token. Behind an authenticating proxy, set `auth: :bearer` and `api_key:`. Its models are configured with `config :omni, :providers, ollama: [models: [...]]`.

**A missing API key is not a boot error.** *(phase 1)* Keys passed per call remain valid; a request without one fails with `{:error, :no_api_key}`, as before.

## Models

**`%Omni.Model{}` fields changed.** *(phase 1)* `provider` is the embedded `%Omni.Provider{}` (was a module). `dialect` becomes `dialects: %{text: Module}`.

**`Omni.Model.new/1`** accepts `provider:` as a struct or a loaded provider id; `dialects:` is optional and filled from the provider. *(phase 1)*

**`Omni.put_model/1`** registers under the model's own provider (was `put_model/2`). The provider must be loaded. *(phase 1)*

**New: `filter:`** in `config :omni, :models` — `{Mod, :fun}` or a 1-arity function over every loaded model, including config-defined ones. *(phase 1)*

**New: per-provider `models:`** — adds models alongside the catalog's (as ids or keyword lists of `Model.new/1` attributes); a matching id replaces the catalog model. *(phase 1)*

**Dialect resolution.** *(phase 1)* Model data decides each model's dialect; the provider's dialect list is derived from its models. A configured `dialects:` value only fills models that have none — it never changes a model that already has one. To change catalog models' dialects, use a provider module's `models/2`.

**Errors.** *(phase 1)* `{:error, {:unknown_provider, id}}` covers both a provider that doesn't exist and one not selected in `providers:`.

## Sources

**`Omni.Source.fetch/2` changed.** *(phase 1)* It takes a provider id (not a module) and returns `{:ok, provider, models}`: a partial `%Omni.Provider{}` from the catalog's provider record, and models without a provider. Sources must try their own dialect mapping; models with none are filled by Omni.

**Skipped models.** *(phase 1)* Both built-in sources skip, with a warning, models whose own npm package maps to no dialect, and models served from a different base URL than their provider.

## Dialects

**New required callback `auth/0`.** *(phase 1)* Returns `:bearer` or `{:header, name}` — the home API's key scheme. Custom dialects must implement it.

**`handle_path/2` returns resource paths only** (`/chat/completions`, not `/v1/chat/completions`). *(phase 1)*
