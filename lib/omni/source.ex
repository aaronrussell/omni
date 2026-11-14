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

  ```elixir
  config :omni, :models, source: Omni.Sources.LLMDB

  config :omni, :providers, openai: [source: Omni.Sources.ModelsDev]
  ```

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

  - `provider` - a `%Omni.Provider{}` with `id`, and whatever the catalog
    knows of `name`, `api_key` (`{:system, var}` when the catalog names
    exactly one environment variable), and `dialects`: an
    `%Omni.Provider.Endpoint{}` per dialect the provider's models speak,
    holding the catalog's whole URL for it. Leave the rest unset.
  - `models` - `%Omni.Model{}` structs **without** a provider. Each model's
    `dialects` comes from the catalog's own data (for example, an npm
    package mapped to a dialect), one per capability the catalog says the
    model serves (see `Omni.Model`). Omni never fills in a missing
    dialect, so skip a model the catalog gives no dialect for.

  Use `endpoints/3` to derive the endpoints from the models' URLs. Keep
  templated URLs (`https://${ACCOUNT}.example.com/v1`) as they are: a
  provider's `host:` config fills the origin, and a request to a URL still
  holding a placeholder returns an error.

  Skip (with a warning) models the source can't represent faithfully — for
  example, a model whose dialect hint is unrecognised, or one served from a
  different URL than other models of its dialect.

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
  alias Omni.Provider.Endpoint

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
  Derives a provider's endpoints from its models' URLs.

  Takes `{model, url}` pairs, where `url` is the model's own URL in the
  catalog or `nil`, the catalog's provider URL, and the dialect the catalog
  names at provider level (or `nil`). Each dialect's endpoint takes the URL
  of its first model by id: the model's own URL, else the provider URL. A
  later model of the same dialect at a different URL can't be served, and
  is returned in `skipped` with its URL. The provider-level dialect gets the provider URL
  when no model claimed it. A provider URL with no dialect is dropped.

  ```elixir
  {endpoints, models, skipped} =
    Omni.Source.endpoints(pairs, "https://api.acme.ai/v1", Omni.Dialects.OpenAICompletions)
  ```
  """
  @spec endpoints([{Model.t(), String.t() | nil}], String.t() | nil, module() | nil) ::
          {%{module() => Endpoint.t()}, [Model.t()], [{Model.t(), String.t()}]}
  def endpoints(pairs, provider_url, provider_dialect) do
    {endpoints, models, skipped} =
      pairs
      |> Enum.sort_by(fn {model, _url} -> model.id end)
      |> Enum.reduce({%{}, [], []}, fn {model, url}, {endpoints, models, skipped} ->
        url = url || provider_url

        conflict =
          Enum.find(model.dialects, fn {_capability, dialect} ->
            match?(%{^dialect => %Endpoint{base_url: other}} when other != url, endpoints)
          end)

        case conflict do
          nil ->
            endpoints =
              Enum.reduce(model.dialects, endpoints, fn {_capability, dialect}, acc ->
                Map.put_new(acc, dialect, %Endpoint{base_url: url})
              end)

            {endpoints, [model | models], skipped}

          {_capability, _dialect} ->
            {endpoints, models, [{model, url} | skipped]}
        end
      end)

    endpoints =
      if provider_dialect,
        do: Map.put_new(endpoints, provider_dialect, %Endpoint{base_url: provider_url}),
        else: endpoints

    {endpoints, Enum.reverse(models), Enum.reverse(skipped)}
  end

  @doc """
  Builds a provider-less `%Omni.Model{}` from a string-keyed data map.

  The shared constructor for model sources. Recognized keys: `"id"`,
  `"name"`, `"dialects"` (a list of dialect string ids, see
  `Omni.Dialect.get/1`, each placed under the capability its module serves:
  `["openai_responses", "openai_decisions"]` gives `%{text: ..., decision:
  ...}`), `"release_date"` (ISO 8601 `YYYY-MM-DD`, or `YYYY-MM` which parses
  as the first of the month), `"reasoning"` (boolean), `"reasoning_options"`,
  `"input_modalities"`/`"output_modalities"` (lists of strings),
  `"input_cost"`, `"output_cost"`, `"cache_read_cost"`, `"cache_write_cost"`,
  `"context_size"`, `"max_output_tokens"`. Costs and limits default to `0`,
  modalities to `["text"]`, reasoning to `false`, and the name to the id.

  `"reasoning_options"` is a list in models.dev's form, which becomes the
  model's `:thinking` map (see `Omni.Model`) when `"reasoning"` is true:

  ```elixir
  [%{"type" => "effort", "values" => ["low", "medium", "high"]},
   %{"type" => "toggle"},
   %{"type" => "budget_tokens", "min" => 1024, "max" => 32_000}]
  ```

  Option maps may have string or atom keys. Unknown types are ignored.

  Raises `ArgumentError` for an unknown dialect string, or for two dialects
  serving the same capability. Modality strings are
  converted with `String.to_atom/1` — filter untrusted data to the modalities
  Omni supports (`:text`, `:image`, `:pdf`) first.
  """
  @spec build_model(map()) :: Model.t()
  def build_model(data) do
    Model.new(
      id: data["id"],
      name: data["name"] || data["id"],
      dialects: build_dialects(data["dialects"] || []),
      release_date: parse_date(data["release_date"]),
      thinking: build_thinking(data["reasoning"], data["reasoning_options"]),
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

  defp build_dialects(names) do
    Enum.reduce(names, %{}, fn name, acc ->
      dialect = Omni.Dialect.get!(name)
      capability = Omni.Dialect.capability(dialect)

      if Map.has_key?(acc, capability) do
        raise ArgumentError,
              "dialects #{inspect(acc[capability])} and #{inspect(dialect)} " <>
                "both serve #{inspect(capability)}"
      end

      Map.put(acc, capability, dialect)
    end)
  end

  defp build_thinking(reasoning, _options) when reasoning in [nil, false], do: false
  defp build_thinking(_reasoning, options) when not is_list(options), do: true

  defp build_thinking(_reasoning, options) do
    Enum.reduce(options, %{}, fn option, acc ->
      option = Map.new(option, fn {key, value} -> {to_string(key), value} end)

      case option["type"] do
        "effort" ->
          values = Enum.filter(option["values"] || [], &is_binary/1)
          Map.update(acc, :efforts, values, &Enum.uniq(&1 ++ values))

        "toggle" ->
          Map.put(acc, :toggle, true)

        "budget_tokens" ->
          Map.put(acc, :budget, {option["min"], option["max"]})

        _ ->
          acc
      end
    end)
  end

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
