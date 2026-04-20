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
  omit the `:dialect` option — the dialect is resolved per-model from the JSON
  data files at load time. See "Multi-dialect providers" below.

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
          Omni.Provider.load_models(__MODULE__, "priv/models/gateway.json")
        end
      end

  When `dialect/0` returns `nil`, `load_models/2` reads the `"dialect"` string
  from each model's JSON entry and resolves it via `Omni.Dialect.get!/1`. If a
  model is missing the `"dialect"` field, loading raises at startup.

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

  Providers are loaded at startup from application config. Built-in providers
  use shorthand atoms; custom providers use `{id, module}` tuples:

      config :omni, :providers, [
        :anthropic,
        :openai,
        acme: MyApp.Providers.Acme
      ]

  To load a provider at runtime without restarting:

      Omni.Provider.load(acme: MyApp.Providers.Acme)

  The provider's models are then available via `Omni.get_model(:acme, "acme-7b")`.
  """

  alias Omni.Model

  @builtin_providers %{
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    groq: Omni.Providers.Groq,
    ollama: Omni.Providers.Ollama,
    openai: Omni.Providers.OpenAI,
    opencode: Omni.Providers.OpenCode,
    openrouter: Omni.Providers.OpenRouter,
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

  Built-in providers use `load_models/2` to read from a JSON data file; custom
  providers can return models from any source:

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

  For multi-dialect providers (where `dialect/0` returns `nil`), `load_models/2`
  resolves each model's dialect from the `"dialect"` field in the JSON data.

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

  @doc """
  Loads models from a JSON file and builds `%Model{}` structs.

  Each model is stamped with the given provider module and a dialect. The
  dialect is resolved in priority order: if the provider declares a dialect
  (via `use Omni.Provider, dialect: Module`), that dialect is used for all
  models. Otherwise, each model's `"dialect"` string from the JSON data is
  resolved via `Omni.Dialect.get!/1`.

  The `path` may be absolute or relative to the provider module's OTP app
  directory (determined via `Application.get_application/1`).
  """
  @spec load_models(module(), String.t()) :: [Model.t()]
  def load_models(module, path) do
    resolved_path =
      if Path.type(path) == :absolute do
        path
      else
        app = Application.get_application(module) || :omni
        Application.app_dir(app, path)
      end

    resolved_path
    |> File.read!()
    |> JSON.decode!()
    |> Enum.map(&build_model(&1, module))
  end

  defp build_model(data, module) do
    dialect = module.dialect() || Omni.Dialect.get!(data["dialect"])

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
