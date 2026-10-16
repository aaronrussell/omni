defmodule Omni.Provider do
  @moduledoc """
  The provider struct, the provider module behaviour, and provider loading.

  A provider is an LLM service: where requests go (`:base_url`), how they are
  authenticated (`:api_key`, `:auth`), extra `:headers`, and which wire
  formats its models speak (`:dialects`). Providers are data — a
  `%Omni.Provider{}` struct assembled once, when the provider loads, and
  embedded in every `%Omni.Model{}` it serves. At request time nothing is
  looked up: the model carries everything.

  ## How a provider is assembled

  Each provider listed in `config :omni, :models, providers: [...]` is built
  from three layers, later layers winning:

  1. **Source data** — the configured `Omni.Source` (the bundled models.dev
     catalog by default) supplies the provider's name, base URL, API key
     environment variable, and its models, with a dialect inferred for each.
  2. **Provider module** — an optional module implementing this behaviour.
     Its `c:config/0` overrides source values; its other callbacks adjust
     models and requests. Built-in providers have one (`Omni.Providers.*`).
  3. **App config** — `config :omni, :providers, <id>: [...]`.

  Values replace; `:headers` merge by key, `:dialects` by capability, and
  `:models` by model id. Keyword lists are treated as maps.

  ## Provider ids

  A provider's id is its catalog key, snake_cased: `:anthropic`,
  `:fireworks_ai`, `:ollama_cloud`. The same id is used for lookups
  (`Omni.get_model(:anthropic, "...")`), config keys, and catalog lookups.
  An id the catalog doesn't know is a custom provider, defined wholly in
  config.

  ## Configuration

      # Select what loads (default: all built-ins)
      config :omni, :models,
        providers: [:builtins, :togetherai, :gpu_box]

      # Configure providers — configuring never enables
      config :omni, :providers,
        anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}],

        # A catalog provider Omni has no module for
        togetherai: [base_url: "https://api.together.xyz/v1"],

        # A custom provider, defined entirely in config
        gpu_box: [
          base_url: "http://gpu-box:8000/v1",
          dialects: %{text: Omni.Dialects.OpenAICompletions},
          auth: :none,
          models: ["qwen3-32b", [id: "llama-3.3-70b", context_size: 128_000]]
        ]

  Per-provider keys:

    * `:name` — display name
    * `:base_url` — the API root, including any version segment
      (`https://api.openai.com/v1`); dialects append resource paths
    * `:api_key` — a string, `{:system, "ENV_VAR"}`, or `{Mod, :fun, args}`
      (see `resolve_auth/1`)
    * `:auth` — how the key is sent: `:bearer`, `{:header, name}`, `:none`,
      or `:dialect` (the default — the scheme of the dialect's home API)
    * `:headers` — extra headers sent on every request (map)
    * `:dialects` — `%{text: Module}` or `%{text: [Module, ...]}`; the
      default for models that don't name one
    * `:module` — a module implementing this behaviour
    * `:models` — additional models, as model ids or keyword lists of
      `Omni.Model.new/1` attributes
    * `:source` — a model source for this provider only (see `Omni.Source`)

  A selected provider with no base URL, or with models but no dialect, is a
  boot error. A model whose dialect can't be resolved is skipped with a
  warning.

  ## Dialects

  Model data decides each model's dialect; the provider's `:dialects` list is
  derived from its models. A configured `:dialects` value fills in models that
  have none and adds to the list — it never changes a model that already has a
  dialect. To change catalog models' dialects, use a provider module's
  `c:models/2` callback.

  ## Provider modules

  A provider module declares `@behaviour Omni.Provider` and implements any of
  the optional callbacks. Built-ins are mapped to their modules
  automatically; for other providers, set `module:` in config:

      defmodule MyApp.Together do
        @behaviour Omni.Provider

        @impl true
        def config, do: [base_url: "https://api.together.xyz/v1"]

        @impl true
        def modify_body(body, _model, _context, _opts) do
          Map.delete(body, "stream_options")
        end
      end

      config :omni, :providers, togetherai: [module: MyApp.Together]

  > #### Provisional {: .warning}
  >
  > The request-time callbacks (`c:modify_request/3`, `c:modify_body/4`,
  > `c:modify_deltas/3`) are provisional and expected to change as provider
  > quirks move into dialect compatibility flags.

  ## Loading at runtime

  Providers load at boot. To load more later:

      Omni.Provider.load([:togetherai, gpu_box: [base_url: "...", ...]])

  Loading an id that is already loaded replaces its provider and models.
  Models obtained earlier keep the provider struct they were built with.
  """

  alias Omni.{Context, Model}

  @enforce_keys [:id]
  defstruct [:id, :name, :base_url, :api_key, :auth, :module, :tier, headers: %{}, dialects: %{}]

  @typedoc "How the API key is sent with each request."
  @type auth :: :bearer | {:header, String.t()} | :none | :dialect

  @typedoc "An API key value, resolved at request time by `resolve_auth/1`."
  @type api_key :: String.t() | {:system, String.t()} | {module(), atom(), list()} | nil

  @typedoc "How a provider was defined: a built-in, catalog data alone, or config alone."
  @type tier :: :verified | :catalog | :custom

  @typedoc "A streaming delta tuple, as produced by `c:Omni.Dialect.handle_event/1`."
  @type delta :: {atom(), map() | term()}

  @typedoc "An LLM provider."
  @type t :: %__MODULE__{
          id: atom(),
          name: String.t() | nil,
          base_url: String.t() | nil,
          api_key: api_key(),
          auth: auth() | nil,
          headers: %{optional(String.t()) => String.t()},
          dialects: %{optional(atom()) => [module()]},
          module: module() | nil,
          tier: tier() | nil
        }

  @doc """
  Returns configuration overrides, applied over source data at load time.

  Accepts the same keys as `config :omni, :providers` except `:module`,
  `:models`, and `:source`. App config overrides these values.

      @impl true
      def config do
        [base_url: "https://api.acme.ai/v1", api_key: {:system, "ACME_API_KEY"}]
      end
  """
  @callback config() :: keyword()

  @doc """
  Adjusts the provider's models at load time.

  Receives the models from the source and config (not yet stamped with the
  provider, possibly without a dialect) and the merged provider. Returns the
  final list.

      @impl true
      def models(models, _provider) do
        Enum.map(models, &%{&1 | input_modalities: Enum.uniq([:pdf | &1.input_modalities])})
      end
  """
  @callback models(models :: [Model.t()], provider :: t()) :: [Model.t()]

  @doc """
  Makes a last change to the finished `%Req.Request{}`, after authentication.

  Use it for request signing, token fetching, or URL rewriting. Returns
  `{:ok, req}`, or `{:error, reason}` when credentials can't be resolved.
  Provisional.
  """
  @callback modify_request(req :: Req.Request.t(), provider :: t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc """
  Adjusts the request body built by the dialect. Provisional.
  """
  @callback modify_body(body :: map(), model :: Model.t(), context :: Context.t(), opts :: map()) ::
              map()

  @doc """
  Adjusts the deltas the dialect parsed from one streaming event. Receives
  the raw event so fields the dialect ignores can be read. Provisional.
  """
  @callback modify_deltas(deltas :: [delta()], raw_event :: map(), model :: Model.t()) ::
              [delta()]

  @optional_callbacks config: 0, models: 2, modify_request: 3, modify_body: 4, modify_deltas: 3

  @doc """
  Returns a loaded provider by id.

      {:ok, provider} = Omni.Provider.get(:anthropic)
      provider.base_url  #=> "https://api.anthropic.com/v1"
  """
  @spec get(atom()) :: {:ok, t()} | {:error, {:unknown_provider, atom()}}
  def get(id) when is_atom(id) do
    case :persistent_term.get(providers_key(), %{}) do
      %{^id => provider} -> {:ok, provider}
      _ -> {:error, {:unknown_provider, id}}
    end
  end

  @doc """
  Loads providers, replacing any already loaded under the same id.

  Each entry is a provider id, read with its `config :omni, :providers`
  entry, or `{id, opts}`, where `opts` layer over that entry.

      Omni.Provider.load([:togetherai])
      Omni.Provider.load(gpu_box: [base_url: "http://gpu-box:8000/v1", dialects: %{text: Omni.Dialects.OpenAICompletions}])

  Raises `ArgumentError` when a provider can't be assembled (see the moduledoc).
  """
  @spec load([atom() | {atom(), keyword() | map()}]) :: :ok
  def load(entries) when is_list(entries), do: Omni.Provider.Loader.load(entries)

  @doc """
  Returns the ids of the built-in providers.
  """
  @spec builtins() :: [atom()]
  def builtins, do: Omni.Provider.Builtins.ids()

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

  @doc false
  @spec callback?(t() | module() | nil, atom(), arity()) :: boolean()
  def callback?(%__MODULE__{module: module}, fun, arity), do: callback?(module, fun, arity)
  def callback?(nil, _fun, _arity), do: false

  def callback?(module, fun, arity) when is_atom(module),
    do: function_exported?(module, fun, arity)

  @doc false
  def providers_key, do: {Omni, :providers}

  @doc false
  def models_key(id), do: {Omni, :models, id}
end
