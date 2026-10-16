defmodule Omni.Source do
  @moduledoc """
  Behaviour for pluggable model data sources.

  > #### Experimental {: .warning}
  >
  > This behaviour is experimental and may change in a future release.

  A source answers one question: *what does your catalog say about this
  provider?* It returns the provider's catalog-level data and its models, in
  one go. Where the data comes from — a bundled snapshot, another package's
  catalog, a file, a network fetch — is entirely the source's concern.

  Omni ships `Omni.Sources.ModelsDev` (the default, reading a bundled
  [models.dev](https://models.dev) snapshot) and `Omni.Sources.LLMDB`. Select
  a source globally or per provider:

      config :omni, :models, source: Omni.Sources.LLMDB

      config :omni, :providers, openai: [source: Omni.Sources.ModelsDev]

  A source value is a module or a `{module, opts}` tuple; `opts` are passed
  to `c:fetch/2`.

  ## The `fetch/2` contract

  `c:fetch/2` receives the provider's canonical id — its catalog key,
  snake_cased (`:anthropic`, `:fireworks_ai`) — and the source's opts.
  Translating the id to the catalog's native key is the source's job:
  `Omni.Sources.ModelsDev` hyphenates it, `Omni.Sources.LLMDB` uses it
  verbatim.

  Return `{:ok, provider, models}` with **raw catalog data only** — Omni
  layers provider modules and config over it afterwards:

    * `provider` — a `%Omni.Provider{}` with `id`, and whatever the catalog
      knows of `name`, `base_url`, `api_key` (`{:system, var}` when the
      catalog names exactly one environment variable), and `dialects` (from
      a provider-level dialect hint). Leave the rest unset.
    * `models` — `%Omni.Model{}` structs **without** a provider. Each model's
      `dialects` comes from the catalog's own data (for example, an npm
      package mapped to a dialect); leave it empty when nothing maps. Omni
      fills empty dialects from the provider afterwards.

  Skip (with a warning) models the source can't represent faithfully — for
  example, a model whose own dialect hint is set but unrecognised, or one
  served from a different base URL than its provider.

  Return `{:error, :unknown_provider}` when the catalog has no such provider;
  Omni then treats it as a custom provider defined in config. Any other error
  is logged and treated the same way.

  Use `build_model/1` to construct models from string-keyed data maps.

  ## Caching expensive work

  `fetch/2` is called once per provider within a load pass (a dozen times for
  the built-ins at boot). Sources that derive models from a shared expensive
  artifact — a large decoded snapshot, a network response — should wrap that
  work in `memo/2`: the result is computed once per pass and garbage collected
  when the pass ends, rather than lingering for the VM's lifetime. See
  `Omni.Sources.ModelsDev` for an example.
  """

  alias Omni.{Model, Provider}

  @typedoc "A source in configuration: a module or a `{module, opts}` tuple."
  @type t :: module() | {module(), keyword()}

  @doc """
  Returns the catalog's provider data and models for a provider id.

  See the module documentation for the contract.
  """
  @callback fetch(id :: atom(), opts :: keyword()) ::
              {:ok, Provider.t(), [Model.t()]} | {:error, term()}

  @cache_key {__MODULE__, :cache}

  @doc """
  Builds a provider-less `%Omni.Model{}` from a string-keyed data map.

  The shared constructor for model sources. Recognized keys: `"id"`,
  `"name"`, `"dialect"` (a dialect string id, see `Omni.Dialect.get/1`, or
  `nil`), `"release_date"` (ISO 8601 `YYYY-MM-DD`, or `YYYY-MM` which parses
  as the first of the month), `"reasoning"`,
  `"input_modalities"`/`"output_modalities"` (lists of strings),
  `"input_cost"`, `"output_cost"`, `"cache_read_cost"`, `"cache_write_cost"`,
  `"context_size"`, `"max_output_tokens"`. Costs and limits default to `0`,
  modalities to `["text"]`, reasoning to `false`, and the name to the id.

  Raises `ArgumentError` for an unknown dialect string. Modality strings are
  converted with `String.to_atom/1` — filter untrusted data to the modalities
  Omni supports (`:text`, `:image`, `:pdf`) first.
  """
  @spec build_model(map()) :: Model.t()
  def build_model(data) do
    Model.new(
      id: data["id"],
      name: data["name"] || data["id"],
      dialects: build_dialects(data["dialect"]),
      release_date: parse_date(data["release_date"]),
      reasoning: data["reasoning"] || false,
      input_modalities: Enum.map(data["input_modalities"] || ["text"], &String.to_atom/1),
      output_modalities: Enum.map(data["output_modalities"] || ["text"], &String.to_atom/1),
      input_cost: data["input_cost"] || 0,
      output_cost: data["output_cost"] || 0,
      cache_read_cost: data["cache_read_cost"] || 0,
      cache_write_cost: data["cache_write_cost"] || 0,
      context_size: data["context_size"] || 0,
      max_output_tokens: data["max_output_tokens"] || 0
    )
  end

  defp build_dialects(nil), do: %{}
  defp build_dialects(name), do: %{text: Omni.Dialect.get!(name)}

  defp parse_date(<<_::binary-size(7)>> = date), do: Date.from_iso8601!(date <> "-01")
  defp parse_date(date) when is_binary(date), do: Date.from_iso8601!(date)
  defp parse_date(_), do: nil

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

  Outside a scope — a one-off `c:fetch/2` call, for example — there is
  nothing to share the result with, so `fun` simply runs. Keys are namespaced
  by convention: use `{YourSource, :name}` tuples.
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
