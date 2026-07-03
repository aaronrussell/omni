defmodule Omni.Provider do
  @moduledoc """
  Behaviour and shared logic for LLM providers.

  A provider represents a specific LLM service — its endpoint, authentication
  mechanism, and any service-specific adaptations. It is the authenticated HTTP
  layer: it knows *where* to send requests and *how* to authenticate them, but
  not *what* the request body should contain (that's the dialect's job).

  Omni separates providers from dialects because the mapping is many-to-one.
  There are ~4–5 wire formats but ~20–30 services. Groq, Together, Fireworks,
  and OpenRouter all speak the OpenAI Chat Completions format — their request
  bodies and streaming events are identical. Only endpoint, authentication, and
  the occasional quirk differ. A provider captures those differences; a dialect
  (see `Omni.Dialect`) handles the wire format shared across many providers.

  Most providers speak a single dialect, but multi-model gateways (like OpenCode
  Zen) route to different upstream APIs depending on the model. These providers
  omit the `:dialect` option — the dialect is resolved per-model from the
  catalog data at load time. See "Multi-dialect providers" below.

  ## Defining a provider

  Use `use Omni.Provider` with an optional `:dialect` option. Most providers
  declare a dialect — the only required callback is `config/0`:

      defmodule MyApp.Providers.Acme do
        use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

        @impl true
        def config do
          %{
            base_url: "https://api.acme.ai",
            api_key: {:system, "ACME_API_KEY"}
          }
        end

        @impl true
        def models do
          [
            Omni.Model.new(
              id: "acme-7b",
              name: "Acme 7B",
              provider: __MODULE__,
              dialect: dialect(),
              context_size: 128_000,
              max_output_tokens: 4096
            )
          ]
        end
      end

  The `use` macro generates a `dialect/0` accessor from the provided module (or
  `nil` when omitted) and default implementations for all optional callbacks.
  Override only what your provider needs — most providers are just `config/0`
  and `models/0`.

  ## The request pipeline

  Understanding the request pipeline clarifies when each callback runs and why.
  Internally, Omni orchestrates the flow by calling dialect and provider
  callbacks via the module references on the `%Model{}` struct:

      # 1. Dialect builds the request body from Omni types
      body = dialect.handle_body(model, context, opts)

      # 2. Provider adjusts the body for service-specific quirks
      body = provider.modify_body(body, context, opts)

      # 3. Dialect determines the URL path for this API
      path = dialect.handle_path(model, opts)

      # 4. Provider builds the full URL (base_url + path)
      url = provider.build_url(path, opts)

      # 5. Provider adds authentication to the request
      {:ok, req} = provider.authenticate(req, opts)

  On the response side, streaming events flow through a similar pipeline:

      # 1. Dialect parses raw SSE JSON into normalized delta tuples
      deltas = dialect.handle_event(raw_event)

      # 2. Provider adjusts deltas for service-specific data
      deltas = provider.modify_events(deltas, raw_event)

  The dialect does the heavy lifting (full type translation); the provider makes
  small, targeted adjustments. Most providers don't override `modify_body/3` or
  `modify_events/2` at all.

  ## Callbacks

  | Callback | Required? | Default |
  |---|---|---|
  | `config/0` | yes | — |
  | `models/0` | no | `[]` |
  | `build_url/2` | no | `opts.base_url <> path` |
  | `authenticate/2` | no | resolves `opts.api_key`, sets header |
  | `modify_body/3` | no | passthrough |
  | `modify_events/2` | no | passthrough |

  ## Authentication

  The default `authenticate/2` resolves `opts.api_key` via `resolve_auth/1` and
  sets the appropriate header. When no `:auth_header` is configured, it sends a
  Bearer token on the `"authorization"` header (the most common scheme). When a
  custom `:auth_header` is set in `config/0` (e.g. `"x-api-key"`), the raw key
  is sent on that header instead.

  Override `authenticate/2` only for unusual schemes like request signing or
  token refresh:

      # Custom authentication
      @impl true
      def authenticate(req, opts) do
        with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
          {:ok, Req.Request.put_header(req, "x-custom-auth", sign(key))}
        end
      end

  API keys are resolved in priority order:

  1. **Call-site opts** — `:api_key` passed directly to `generate_text/3` or
     `stream_text/3`
  2. **Application config** — `config :omni, MyProvider, api_key: ...`
  3. **Provider default** — the `:api_key` value from `config/0`

  All three tiers accept the same value types — see `resolve_auth/1`.

  ## Config keys

  `config/0` returns a map with the following keys:

    * `:base_url` (required) — the service's base URL
    * `:api_key` — default API key (see `resolve_auth/1` for accepted formats)
    * `:auth_header` — custom header name for the API key; when set, the raw
      key is sent on this header instead of as a Bearer token on `"authorization"`
    * `:headers` — additional headers to include on every request (map)

  These values serve as defaults. Users can override `:base_url`, `:api_key`,
  and `:headers` at the application config level or at the call site.

  ## Multi-dialect providers

  Some providers act as gateways to multiple upstream APIs, each with its own
  wire format. For example, OpenCode Zen routes Claude models through the
  Anthropic Messages format and GPT models through OpenAI Responses.

  These providers omit the `:dialect` option:

      defmodule MyApp.Providers.Gateway do
        use Omni.Provider

        @impl true
        def config do
          %{base_url: "https://gateway.example.com", api_key: {:system, "GW_KEY"}}
        end

        @impl true
        def models do
          Omni.Provider.load_models(__MODULE__, provider_id: :gateway)
        end
      end

  The model source resolves each model's dialect from its catalog data (see
  `Omni.Sources.ModelsDev` for how the default source infers dialects). The
  provider's declared dialect is only a fallback for models without one — when
  `dialect/0` returns `nil`, a model whose dialect the source cannot resolve
  is skipped with a warning.

  ## Model sources

  Model catalog data comes from a pluggable source — see `Omni.Source`.
  `load_models/2` resolves the source per call, in priority order:

  1. **Per-module config** — `config :omni, Omni.Providers.OpenAI, source: ...`
  2. **Call-site opt** — `load_models(__MODULE__, source: ...)` (a provider
     author's default for that provider)
  3. **Global config** — `config :omni, :models, source: ...`
  4. **Default** — `Omni.Sources.ModelsDev` (bundled models.dev snapshot)

  A source value is a module or a `{module, opts}` tuple. Unlike API keys,
  the user's provider-specific config beats the call site here, because the
  call site is provider-author code rather than end-user code.

  ## Choosing a dialect

  Pick the dialect that matches your provider's wire format:

    * `Omni.Dialects.OpenAICompletions` — OpenAI Chat Completions format, used
      by the majority of providers (Groq, Together, Fireworks, DeepSeek, etc.)
    * `Omni.Dialects.OpenAIResponses` — OpenAI's newer Responses API format
    * `Omni.Dialects.AnthropicMessages` — Anthropic Messages format
    * `Omni.Dialects.GoogleGemini` — Google Gemini format
    * `Omni.Dialects.OllamaChat` — Ollama native chat format (NDJSON streaming)

  If your provider speaks a format not listed here, you'll need to implement a
  new dialect — see `Omni.Dialect` for the behaviour specification.

  ## Registering a provider

  All built-in providers are loaded at startup. To restrict which built-ins
  load, or to add custom providers, use the `providers:` key of the `:models`
  config (bare atoms name built-ins; `{id, module}` pairs register custom
  providers; the default is `:all`):

      config :omni, :models,
        providers: [
          :anthropic,
          :openai,
          acme: MyApp.Providers.Acme
        ]

  To load a provider at runtime without restarting:

      Omni.Provider.load(acme: MyApp.Providers.Acme)

  The provider's models are then available via `Omni.get_model(:acme, "acme-7b")`.
  """

  require Logger

  alias Omni.Model

  @builtin_providers %{
    alibaba: Omni.Providers.Alibaba,
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    groq: Omni.Providers.Groq,
    moonshot: Omni.Providers.Moonshot,
    nearai: Omni.Providers.NearAI,
    ollama: Omni.Providers.Ollama,
    openai: Omni.Providers.OpenAI,
    opencode: Omni.Providers.OpenCode,
    openrouter: Omni.Providers.OpenRouter,
    venice: Omni.Providers.Venice,
    zai: Omni.Providers.Zai
  }

  @doc """
  Returns the provider's base configuration map.

  This is the only required callback. The map should include `:base_url` and
  typically `:api_key`. Optional keys are `:auth_header` (defaults to
  `"authorization"`) and `:headers` (additional headers as a map).

      @impl true
      def config do
        %{
          base_url: "https://api.acme.ai",
          auth_header: "x-api-key",
          api_key: {:system, "ACME_API_KEY"},
          headers: %{"x-api-version" => "2024-01-01"}
        }
      end

  These values serve as defaults — users can override `:base_url`, `:api_key`,
  and `:headers` via application config or call-site options.
  """
  @callback config() :: map()

  @doc """
  Returns the provider's list of model structs.

  Built-in providers call `load_models/2`, which pulls catalog data from the
  configured model source (see `Omni.Source`). Custom providers can do the
  same with a `provider_id:` naming their entry in the source's catalog:

      @impl true
      def models do
        Omni.Provider.load_models(__MODULE__, provider_id: :acme)
      end

  Or build model structs directly:

      @impl true
      def models do
        [
          Omni.Model.new(
            id: "acme-7b",
            name: "Acme 7B",
            provider: __MODULE__,
            dialect: dialect(),
            context_size: 128_000,
            max_output_tokens: 4096
          )
        ]
      end

  Default: `[]` (no models).
  """
  @callback models() :: [Model.t()]

  @doc """
  Builds the full request URL from a dialect-provided path and the merged
  options map.

  The `opts` map contains `:base_url` (from the three-tier config merge) plus
  all validated inference options. The `path` comes from the dialect's
  `c:Omni.Dialect.handle_path/2` callback (e.g. `"/v1/chat/completions"`).

  Default: `opts.base_url <> path`.

  Override when URL structure deviates from simple concatenation — for example,
  Azure OpenAI reorganizes the path around deployment names and API versions.
  """
  @callback build_url(path :: String.t(), opts :: map()) :: String.t()

  @doc """
  Adds authentication to a `%Req.Request{}`.

  Receives the built request and the merged options map (which includes
  `:api_key` and `:auth_header` from the three-tier config merge). Returns
  `{:ok, req}` with authentication applied, or `{:error, reason}` if the
  key cannot be resolved.

  This is the only callback that returns an ok/error tuple, because
  authentication depends on external state (environment variables, vaults,
  token endpoints) that can fail at runtime.

  Default: resolves `opts.api_key` via `resolve_auth/1` and sends a Bearer
  token on `"authorization"`. When `:auth_header` is set in config, sends the
  raw key on that header instead. Override for request signing (e.g. AWS
  SigV4) or token refresh flows.
  """
  @callback authenticate(req :: Req.Request.t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc """
  Adjusts the dialect-built request body for this provider's quirks.

  Called after `c:Omni.Dialect.handle_body/3` with the body map it produced,
  the original `%Context{}`, and the validated options. The context is
  available for per-message transformations (e.g. encoding round-trip data
  from `Message.private` onto wire-format messages). Returns the modified body.

  Default: passthrough (returns body unchanged). Override when the provider
  speaks a standard dialect but needs small adjustments — an extra field, a
  renamed parameter, a restructured sub-object. For example, OpenRouter
  remaps `reasoning_effort` into its own `reasoning` object.
  """
  @callback modify_body(body :: map(), context :: Omni.Context.t(), opts :: map()) :: map()

  @doc """
  Adjusts dialect-parsed delta tuples for this provider's quirks.

  Called after `c:Omni.Dialect.handle_event/1` with the list of delta tuples
  it produced and the original raw SSE event map. The raw event is passed so
  the provider can inspect fields the dialect doesn't know about. Returns the
  modified delta list — you can modify, remove, or append deltas.

  See `Omni.Dialect` for the delta tuple types and their expected map shapes.

  Default: passthrough (returns deltas unchanged). Override when the provider
  embeds extra data in streaming events that the shared dialect doesn't parse.
  For example, OpenRouter extracts `reasoning_details` from the raw event and
  appends a `:message` delta carrying private data.
  """
  @callback modify_events(deltas :: [{atom(), map() | term()}], raw_event :: map()) ::
              [{atom(), map() | term()}]

  @doc """
  Resolves an API key value to a literal string.

  Supports multiple formats:

  - `"sk-..."` — a literal string, returned as-is
  - `{:system, "ENV_VAR"}` — resolved from the environment
  - `{Module, :function, args}` — resolved via `apply/3`
  - `nil` — returns `{:error, :no_api_key}`
  """
  @spec resolve_auth(term()) :: {:ok, String.t()} | {:error, term()}
  def resolve_auth(value) when is_binary(value), do: {:ok, value}

  def resolve_auth({:system, env_var}) when is_binary(env_var) do
    case System.get_env(env_var) do
      nil -> {:error, {:missing_env_var, env_var}}
      value -> {:ok, value}
    end
  end

  def resolve_auth({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    case apply(mod, fun, args) do
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_auth_value, other}}
    end
  rescue
    e -> {:error, e}
  end

  def resolve_auth(nil), do: {:error, :no_api_key}

  @doc """
  Loads providers' models into `:persistent_term`.

  Accepts a list of built-in provider atoms or `{id, module}` tuples for
  custom providers. Models are merged with any existing entries for that
  provider, so calling `load/1` multiple times is safe.

      # Load a built-in provider on demand
      Omni.Provider.load([:openrouter])

      # Load a custom provider
      Omni.Provider.load(my_llm: MyApp.Providers.CustomLLM)
  """
  @spec load([atom() | {atom(), module()}]) :: :ok
  def load(providers) when is_list(providers) do
    # The cache scope lets sources share expensive work (like decoding a
    # catalog snapshot) across the pass and release it when the pass ends.
    Omni.Source.with_cache(fn ->
      for provider <- providers do
        {id, mod} = normalize_provider(provider)

        models =
          try do
            mod.models()
          rescue
            e ->
              reraise "failed to load models for provider #{inspect(id)} (#{inspect(mod)}): " <>
                        Exception.message(e),
                      __STACKTRACE__
          end

        model_map = Map.new(models, &{&1.id, &1})
        existing = :persistent_term.get({Omni, id}, %{})
        :persistent_term.put({Omni, id}, Map.merge(existing, model_map))

        existing_ids = :persistent_term.get({Omni, :provider_ids}, %{})
        :persistent_term.put({Omni, :provider_ids}, Map.put(existing_ids, mod, id))
      end
    end)

    :ok
  end

  @doc false
  def builtin_providers, do: @builtin_providers

  defp normalize_provider({_id, _mod} = pair), do: pair

  defp normalize_provider(id) when is_atom(id) do
    case @builtin_providers[id] do
      nil ->
        raise ArgumentError,
              "unknown built-in provider #{inspect(id)} — " <>
                "use {id, module} for custom providers"

      mod ->
        {id, mod}
    end
  end

  @doc false
  @spec providers_from_config(term()) :: [atom() | {atom(), module()}]
  def providers_from_config(nil), do: Map.keys(@builtin_providers)

  def providers_from_config(config) when is_list(config) do
    if Keyword.keyword?(config) and
         Enum.all?(Keyword.keys(config), &(&1 in [:source, :providers])) do
      expand_providers(Keyword.get(config, :providers, :all))
    else
      raise ArgumentError, config_migration_message(config)
    end
  end

  def providers_from_config(config), do: raise(ArgumentError, config_migration_message(config))

  defp expand_providers(:all), do: Map.keys(@builtin_providers)
  defp expand_providers(providers) when is_list(providers), do: providers

  defp expand_providers(other) do
    raise ArgumentError,
          "invalid providers: value #{inspect(other)} in config :omni, :models — " <>
            "expected :all or a list of provider atoms / {id, module} pairs"
  end

  @doc false
  @spec config_migration_message(term()) :: String.t()
  def config_migration_message(config) do
    """
    model loading config moved from :providers to :models.

    Old:  config :omni, :providers, [:anthropic, :openai, acme: MyApp.Acme]

    New:  config :omni, :models,
            # optional — an Omni.Source module or {module, opts};
            # default Omni.Sources.ModelsDev
            source: Omni.Sources.ModelsDev,
            # :all (the default), or built-in ids and {id, module} pairs
            providers: [:anthropic, :openai, acme: MyApp.Acme]

    Got: #{inspect(config)}
    """
  end

  @doc """
  Loads a provider's models from the configured model source.

  Resolves the source (see the "Model sources" section in the moduledoc for
  the resolution order), calls its `c:Omni.Source.fetch/2`, and returns the
  models. When the source returns an error — most commonly
  `:unknown_provider` for a module the source cannot match to a catalog
  entry — a warning is logged and `[]` is returned; models never silently
  load from a source the user didn't configure.

  ## Options

    * `:source` — a source override for this call: a module or a
      `{module, opts}` tuple. Intended for provider authors setting their
      provider's default source; user config for the provider module still
      wins.
    * `:provider_id` — the caller's identity in the source's catalog. Required
      for custom providers, which cannot be looked up in
      `builtin_providers/0`.

  All options (except `:source`) are passed through to the source's `fetch/2`,
  merged over the source's own configured opts, so sources can define
  additional call-site options.
  """
  @spec load_models(module(), keyword()) :: [Model.t()]
  def load_models(module, opts \\ [])

  def load_models(module, file) when is_binary(file) do
    raise ArgumentError, """
    load_models/2 no longer accepts a file path (got #{inspect(file)} for \
    #{inspect(module)}).

    Model data now comes from pluggable sources (see Omni.Source). To load \
    this provider's models from the configured source's catalog:

        def models, do: Omni.Provider.load_models(__MODULE__, provider_id: :your_catalog_id)

    Or build %Omni.Model{} structs directly in models/0.
    """
  end

  def load_models(module, opts) when is_list(opts) do
    {source, source_opts} = resolve_source(module, opts)
    fetch_opts = Keyword.merge(source_opts, Keyword.delete(opts, :source))

    case source.fetch(module, fetch_opts) do
      {:ok, models} ->
        models

      {:error, reason} ->
        Logger.warning(
          "failed to load models for #{inspect(module)}: #{inspect(source)} returned " <>
            "#{inspect(reason)} (provider_id: #{inspect(fetch_opts[:provider_id])}) — " <>
            "returning no models. Custom providers must pass provider_id: to " <>
            "load_models/2; to use a different source for this provider: " <>
            "config :omni, #{inspect(module)}, source: MySource"
        )

        []
    end
  end

  defp resolve_source(module, opts) do
    configured =
      Application.get_env(:omni, module, [])[:source] || opts[:source] || global_source() ||
        Omni.Sources.ModelsDev

    normalize_source(configured)
  end

  defp global_source do
    case Application.get_env(:omni, :models) do
      config when is_list(config) -> if Keyword.keyword?(config), do: config[:source]
      _ -> nil
    end
  end

  defp normalize_source({module, opts}) when is_atom(module) and is_list(opts) do
    validate_source!(module)
    {module, opts}
  end

  defp normalize_source(module) when is_atom(module), do: normalize_source({module, []})

  defp normalize_source(other) do
    raise ArgumentError,
          "invalid model source #{inspect(other)} — expected a module or " <>
            "a {module, opts} tuple"
  end

  defp validate_source!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2) do
      raise ArgumentError,
            "#{inspect(module)} is not an Omni.Source — it does not export fetch/2"
    end
  end

  @doc """
  Builds a `%Model{}` struct from a string-keyed data map.

  The shared constructor used by model sources (see `Omni.Source`). The model
  is stamped with the given provider module and a dialect, resolved in
  priority order: the data's `"dialect"` string via `Omni.Dialect.get!/1`,
  falling back to the provider's declared dialect (via `use Omni.Provider,
  dialect: Module`). Raises `ArgumentError` when neither resolves.

  Recognized keys: `"id"`, `"name"`, `"dialect"`, `"release_date"` (ISO 8601
  `YYYY-MM-DD`, or `YYYY-MM` which parses as the first of the month),
  `"reasoning"`, `"input_modalities"`/`"output_modalities"` (lists of
  strings), `"input_cost"`, `"output_cost"`, `"cache_read_cost"`,
  `"cache_write_cost"`, `"context_size"`, `"max_output_tokens"`. Costs and
  limits default to `0`, modalities to `["text"]`, reasoning to `false`.

  Modality strings are converted with `String.to_atom/1` — callers feeding
  data from untrusted or unpruned catalogs must filter them against
  `Omni.Model.supported_modalities/1` first.
  """
  @spec build_model(module(), map()) :: Model.t()
  def build_model(module, data) do
    dialect =
      case data["dialect"] do
        nil ->
          module.dialect() ||
            raise(
              ArgumentError,
              "no dialect specified for model #{inspect(data["id"])} — the model data " <>
                "has no \"dialect\" field and #{inspect(module)} declares no dialect"
            )

        name ->
          Omni.Dialect.get!(name)
      end

    Model.new(
      id: data["id"],
      name: data["name"],
      provider: module,
      dialect: dialect,
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

  defp parse_date(<<_::binary-size(7)>> = date), do: Date.from_iso8601!(date <> "-01")
  defp parse_date(date) when is_binary(date), do: Date.from_iso8601!(date)
  defp parse_date(_), do: nil

  defmacro __using__(opts) do
    dialect = Keyword.get(opts, :dialect)

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

          value =
            if header == "authorization",
              do: "Bearer #{key}",
              else: key

          {:ok, Req.Request.put_header(req, header, value)}
        end
      end

      @impl Omni.Provider
      def modify_body(body, _context, _opts), do: body

      @impl Omni.Provider
      def modify_events(deltas, _raw_event), do: deltas

      defoverridable models: 0,
                     build_url: 2,
                     authenticate: 2,
                     modify_body: 3,
                     modify_events: 2
    end
  end
end
