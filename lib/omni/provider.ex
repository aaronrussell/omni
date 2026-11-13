defmodule Omni.Provider do
  @moduledoc """
  The provider struct, the provider module behaviour, and provider loading.

  A provider is an LLM service: how requests are authenticated (`:api_key`,
  `:auth`), extra `:headers`, and the wire formats it serves (`:dialects`),
  each at an endpoint with its own URL and its own deviations from the
  format (see `Omni.Provider.Endpoint`). Providers are data — a
  `%Omni.Provider{}` struct assembled once, when the provider loads, and
  embedded in every `%Omni.Model{}` it serves. At request time nothing is
  looked up: the model carries everything.

  ## Built-in providers

  Omni ships a provider module for each built-in provider, and loads them all
  by default. The [Built-in providers](built-in-providers.md) guide lists
  them, with each one's id, API key variable and quirks.

  ## Built-in, catalog, and custom providers

  Any provider can be loaded, but Omni knows more about some than others:

    * **Built-in** — Omni ships a module for it, which sets whatever compat
      flags it needs.
    * **Catalog** — any other provider in the source's catalog, such as
      `:fireworks_ai`. Omni takes its endpoint URLs, API key variable,
      models and their dialects from catalog data, and speaks each dialect
      with no compat flags. It may work as is; if it doesn't, set the flags
      it needs yourself, or copy a built-in's with `like:` (see
      [Compat flags](#module-compat-flags)).
    * **Custom** — a provider the catalog doesn't know, defined wholly in
      config.

  To check a model works with your configuration, whatever kind of provider
  serves it, run `mix omni.verify` (see `Mix.Tasks.Omni.Verify`).

  ## How a provider is assembled

  Each provider listed in `config :omni, :models, providers: [...]` is built
  from three layers, later layers winning:

  1. **Source data** — the configured `Omni.Source` (the bundled models.dev
     catalog by default) supplies the provider's name, API key environment
     variable, an endpoint URL for each dialect its models speak, and the
     models, each with the dialect the catalog gives it.
  2. **Provider module** — an optional module implementing this behaviour.
     Its `c:config/0` overrides source values; its other callbacks adjust
     models and requests. Built-in providers have one.
  3. **App config** — `config :omni, :providers, <id>: [...]`.

  Values replace; `:headers` merge by key, `:dialects` by dialect module and
  then by field (`:base_url` replaces, `:compat` merges by flag), and
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

        # Another machine, same paths
        ollama: [host: "http://gpu-box:11434"],

        # A custom provider, defined entirely in config
        gpu_box: [
          dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]},
          auth: :none,
          models: [
            [id: "qwen3-32b", dialects: %{text: Omni.Dialects.OpenAICompletions}],
            [id: "llama-3.3-70b", context_size: 128_000, dialects: %{text: Omni.Dialects.OpenAICompletions}]
          ]
        ]

  Per-provider keys:

    * `:name` — display name
    * `:host` — an origin (`scheme://host[:port]`) that replaces the origin
      of every endpoint URL from the catalog and the provider module (see
      [Endpoints](#module-endpoints))
    * `:api_key` — a string, `{:system, "ENV_VAR"}`, or `{Mod, :fun, args}`
      (see `resolve_auth/1`)
    * `:auth` — how the key is sent: `:bearer`, `{:header, name}`, `:none`,
      or `:dialect` (the default — the scheme of the dialect's home API)
    * `:headers` — extra headers sent on every request (map)
    * `:dialects` — the provider's endpoints, keyed by dialect module:
      `%{Module => [base_url: "...", compat: [...]]}`
    * `:module` — a module implementing this behaviour
    * `:models` — models to correct or add, as model ids or keyword lists of
      `Omni.Model.new/1` attributes (see [Models](#module-models))
    * `:source` — a model source for this provider only (see `Omni.Source`)

  A missing API key or endpoint URL is not an error at boot: a key can be
  passed per request, and a request to an endpoint with no URL returns
  `{:error, {:no_base_url, dialect}}`.

  ## Endpoints

  Each dialect a provider serves has an endpoint holding its whole base URL,
  version segment included, and its compat flags. A request goes to the
  endpoint's base URL plus the dialect's resource path:

      # dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.together.ai/v1"]}
      # POST https://api.together.ai/v1/chat/completions

  A gateway that serves several dialects has an endpoint for each, at
  whatever URL the catalog gives it — on another path or another host.

  URLs are set in three places, each doing one thing:

  | Where | Sets | When |
  | --- | --- | --- |
  | `dialects: %{Module => [base_url: url]}` | one endpoint's whole URL | load |
  | provider `host:` | the origin of every endpoint URL from the catalog or the module | load |
  | `host:` request option | the origin of this request's URL | request |

  `host:` is an origin only — scheme, host and port — and keeps each URL's
  path: `ollama: [host: "http://gpu:11434"]` sends chat to
  `http://gpu:11434/api/chat`. It suits another machine, a region, a proxy
  on the same paths, or a catalog URL templated in its origin
  (`https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1`). To change a path, set
  the endpoint's URL. An endpoint URL written in app config is used as
  written; the `host:` request option overrides everything.

  A dialect key with `[]` declares that the provider serves the dialect;
  its URL then comes from the catalog or the provider module.

  ## Models

  Each model's dialect comes from catalog data, or from the provider
  module's `c:models/2`. Omni never fills one in: a catalog model with no
  dialect, or with a dialect the provider has no endpoint for, is skipped
  with a warning.

  A `:models` entry whose id the catalog has merges over the catalog model,
  field by field (`:dialects` by capability), which corrects catalog data
  without restating it:

      config :omni, :providers,
        openai: [models: [[id: "gpt-6", context_size: 1_000_000]]]

  An entry with a new id adds a model, and names its dialect. A config
  model with no dialect, or one the provider has no endpoint for, raises at
  load. The provider module's `c:models/2` runs after entries are merged, so
  a module can stamp a dialect on them (the built-in `:ollama` provider's does).

  ## Compat flags

  Many providers speak a dialect with small deviations from the API it is
  named after — a different field for max tokens, another way of switching
  thinking on. Compat flags describe those deviations, and the dialect reads
  them while it encodes. The flags a dialect understands are listed in its
  moduledoc (see `Omni.Dialects.OpenAICompletions`); unknown flags are a boot
  error.

  Flags are set on the endpoint of the dialect they apply to:

      config :omni, :providers,
        gpu_box: [
          dialects: %{
            Omni.Dialects.OpenAICompletions => [
              base_url: "http://gpu-box:8000/v1",
              compat: [max_tokens_field: "max_tokens", omit: [:cache]]
            ]
          }
        ]

  `like:` copies a built-in provider's flags for the same dialect. It suits
  catalog providers that are a built-in under another name, such as a
  regional endpoint or a separate plan:

      config :omni, :providers,
        zai_coding_plan: [dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :zai]]}]

  Flags listed alongside `like:` are layered over the copied ones. Flags
  merge one at a time over a built-in's own, so setting one flag leaves the
  others in place.

  ## Provider modules

  A provider module declares `@behaviour Omni.Provider` and implements any of
  the optional callbacks. Built-ins are mapped to their modules
  automatically; for other providers, set `module:` in config:

      defmodule MyApp.Together do
        @behaviour Omni.Provider

        @impl true
        def config do
          [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://api.together.xyz/v1"]}]
        end

        @impl true
        def modify_body(body, _model, _context, _opts) do
          Map.delete(body, "stream_options")
        end
      end

      config :omni, :providers, togetherai: [module: MyApp.Together]

  Reach for compat flags first; module callbacks are for what flags can't
  express, such as a quirk only some of a provider's models have.

  ## Migrating from v1 config

  Provider-level `base_url:` and `compat:`, and `dialects: %{text: Module}`,
  raise at boot with a message showing the new form: `host:` when only the
  origin changes, otherwise the endpoint under `dialects:`.

  ## Loading at runtime

  Providers load at boot. To load more later:

      Omni.Provider.load([:togetherai, gpu_box: [dialects: %{...}, models: [...]]])

  Loading an id that is already loaded replaces its provider and models.
  Models obtained earlier keep the provider struct they were built with.
  """

  alias Omni.{Context, Model}
  alias Omni.Provider.Endpoint

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :api_key,
    :auth,
    :module,
    headers: %{},
    dialects: %{}
  ]

  @typedoc "How the API key is sent with each request."
  @type auth :: :bearer | {:header, String.t()} | :none | :dialect

  @typedoc "An API key value, resolved at request time by `resolve_auth/1`."
  @type api_key :: String.t() | {:system, String.t()} | {module(), atom(), list()} | nil

  @typedoc "An LLM provider."
  @type t :: %__MODULE__{
          id: atom(),
          name: String.t() | nil,
          api_key: api_key(),
          auth: auth() | nil,
          headers: %{optional(String.t()) => String.t()},
          dialects: %{optional(module()) => Endpoint.t()},
          module: module() | nil
        }

  @doc """
  Returns configuration overrides, applied over source data at load time.

  Accepts `:name`, `:api_key`, `:auth`, `:headers` and `:dialects`, as in
  `config :omni, :providers`. App config overrides these values.

      @impl true
      def config do
        [
          api_key: {:system, "ACME_API_KEY"},
          dialects: %{
            Omni.Dialects.OpenAICompletions => [
              base_url: "https://api.acme.ai/v1",
              compat: [max_tokens_field: "max_tokens"]
            ]
          }
        ]
      end

  A built-in's flags are copied by dialect with `like:`.
  """
  @callback config() :: keyword()

  @doc """
  Adjusts the provider's models at load time.

  Receives the models from the source, with config entries merged in (not
  yet stamped with the provider; config models may have no dialect yet),
  and the merged provider. Returns the final list. Models still without a
  dialect afterwards are skipped (catalog) or raise (config).

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
  """
  @callback modify_request(req :: Req.Request.t(), provider :: t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc """
  Adjusts the request body built by the dialect.

  For quirks compat flags can't express — typically ones that depend on the
  model. The body is the dialect's output, already shaped by any compat
  flags. The third argument is what is being sent, and so tells the
  capability: a `%Omni.Context{}` for text generation, a `%Omni.Decision{}`
  for a decision. Match on it to touch only one kind of request:

      @impl true
      def modify_body(body, _model, %Omni.Context{}, _opts), do: Map.delete(body, "stream_options")
      def modify_body(body, _model, _decision, _opts), do: body
  """
  @callback modify_body(
              body :: map(),
              model :: Model.t(),
              input :: Context.t() | Omni.Decision.t(),
              opts :: map()
            ) :: map()

  @optional_callbacks config: 0, models: 2, modify_request: 3, modify_body: 4

  @doc """
  Returns a loaded provider by id.

      {:ok, provider} = Omni.Provider.get(:anthropic)
      provider.name  #=> "Anthropic"
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
      Omni.Provider.load(gpu_box: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]}])

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

  @doc """
  Returns the provider's endpoint for a dialect.

      {:ok, provider} = Omni.Provider.get(:anthropic)
      {:ok, endpoint} = Omni.Provider.endpoint(provider, Omni.Dialects.AnthropicMessages)
      endpoint.base_url  #=> "https://api.anthropic.com/v1"
  """
  @spec endpoint(t(), module()) :: {:ok, Endpoint.t()} | {:error, {:no_endpoint, module()}}
  def endpoint(%__MODULE__{dialects: dialects}, dialect) do
    case dialects do
      %{^dialect => %Endpoint{} = endpoint} -> {:ok, endpoint}
      _ -> {:error, {:no_endpoint, dialect}}
    end
  end

  @doc false
  # The provider's dialect modules for a capability, sorted.
  @spec dialects(t(), atom()) :: [module()]
  def dialects(%__MODULE__{dialects: dialects}, capability) do
    dialects
    |> Map.keys()
    |> Enum.filter(&(Omni.Dialect.capability(&1) == capability))
    |> Enum.sort()
  end

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
