defmodule Omni.Source do
  @moduledoc """
  Behaviour for pluggable model data sources.

  > #### Experimental {: .warning}
  >
  > This behaviour is experimental and may change in a future release.

  A source answers one question: *give me the models for this provider*.
  `Omni.Provider.load_models/2` resolves the configured source and calls
  `c:fetch/2`; where the data comes from — a bundled snapshot, another
  package's catalog, a file, a network fetch — is entirely the source's
  concern.

  Omni ships `Omni.Sources.ModelsDev` (the default, reading a bundled
  [models.dev](https://models.dev) snapshot). See `Omni.Provider` for how
  sources are configured and resolved.

  ## The `fetch/2` contract

  `c:fetch/2` receives the provider module and a keyword list of options —
  the source's configured opts (from `{module, opts}` config) merged with
  the call-site opts passed to `Omni.Provider.load_models/2`, call-site
  winning. All options are passed through, so sources may define their own;
  every source should honor `:provider_id`, the caller's identity in the
  source's catalog (used by custom providers, which cannot be reverse-looked-up
  in `Omni.Provider.builtin_providers/0`).

  On success, return `{:ok, models}` — an empty list is a valid result
  (a known provider whose models were all filtered out). Return
  `{:error, :unknown_provider}` when the provider is not in the source's
  catalog; any other error term is also legal and treated the same way by
  `load_models/2` (a logged warning and an empty model list — there is no
  cross-source fallback).

  ## Model struct invariants

  Sources return ready-to-use `%Omni.Model{}` structs, not intermediate maps.
  Every returned model must satisfy:

    * `id` — present; the provider's model identifier string
    * `provider` — the module passed to `fetch/2`
    * `dialect` — a resolved dialect **module, never `nil`**

  Beware the dialect invariant: `Omni.Model` enforces the `:dialect` key, but
  `@enforce_keys` only rejects an *omitted* key — `Omni.Model.new(dialect: nil)`
  builds silently. Dialect resolution is the source's responsibility; a model
  whose dialect cannot be resolved must be skipped (with a warning) or raise,
  per the source's error policy.

  Use `Omni.Provider.build_model/2` to construct models from string-keyed data
  maps — it implements the dialect precedence (data `"dialect"` wins, the
  provider's declared dialect is the fallback), date parsing, and field
  defaults shared by the built-in sources.

  ## Caching expensive work

  `fetch/2` is called once per provider within a load pass (a dozen times for
  the built-ins at boot). Sources that derive models from a shared expensive
  artifact — a large decoded snapshot, a network response — should wrap that
  work in `memo/2`: the result is computed once per pass and garbage collected
  when the pass ends, rather than lingering for the VM's lifetime. See
  `Omni.Sources.ModelsDev` for an example.
  """

  @typedoc "A source in configuration: a module or a `{module, opts}` tuple."
  @type t :: module() | {module(), keyword()}

  @doc """
  Returns the models for the given provider module.

  See the module documentation for the option-merging semantics, the
  `{:error, :unknown_provider}` convention, and the invariants returned
  models must satisfy.
  """
  @callback fetch(provider :: module(), opts :: keyword()) ::
              {:ok, [Omni.Model.t()]} | {:error, term()}

  @cache_key {__MODULE__, :cache}

  @doc """
  Runs `fun` inside a cache scope for `memo/2`, on the calling process.

  `Omni.Provider.load/1` wraps each load pass in a scope so that every
  `memo/2` result is shared across the pass's `fetch/2` calls and released
  when the pass ends — the scope is cleared and the process's garbage is
  collected, so pass-transient data (like a decoded catalog) does not linger
  on the caller's heap. Nested calls reuse the enclosing scope.
  """
  @spec with_cache((-> result)) :: result when result: var
  def with_cache(fun) do
    if Process.get(@cache_key) do
      fun.()
    else
      Process.put(@cache_key, %{})

      try do
        fun.()
      after
        Process.delete(@cache_key)
        :erlang.garbage_collect()
      end
    end
  end

  @doc """
  Memoizes `fun`'s result under `key` for the duration of the enclosing cache
  scope (see `with_cache/1`).

  Outside a scope — a one-off `Omni.Provider.load_models/2` call, for
  example — there is nothing to share the result with, so `fun` simply runs.
  Keys are namespaced by convention: use `{YourSource, :name}` tuples.
  """
  @spec memo(term(), (-> result)) :: result when result: var
  def memo(key, fun) do
    case Process.get(@cache_key) do
      nil ->
        fun.()

      %{^key => value} ->
        value

      cache ->
        value = fun.()
        Process.put(@cache_key, Map.put(cache, key, value))
        value
    end
  end
end
