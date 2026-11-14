defmodule Omni.Provider do
  @moduledoc """
  The provider struct, the provider module behaviour, and provider loading.

  A provider is an LLM service: how its requests are authenticated, and
  the dialects it serves, each at an endpoint with its own URL. Providers
  are data. The struct is assembled once, when the provider loads, and
  embedded in every `Omni.Model` it serves, so nothing is looked up when a
  request is made.

  [Providers and models](providers-and-models.md) covers choosing and
  configuring providers, and [Built-in providers](built-in-providers.md)
  lists the ones Omni ships. This page is the reference for the struct, for
  how one is assembled, and for writing a provider module.

  ```elixir
  {:ok, provider} = Omni.get_provider(:anthropic)

  provider.name      #=> "Anthropic"
  provider.dialects  #=> %{Omni.Dialects.AnthropicMessages => %Omni.Provider.Endpoint{...}}
  ```

  ## Struct fields

  - `:id` - the provider's id: its catalog key in snake case
    (`:fireworks_ai`), or a name of your own for a custom provider. Config,
    lookups and model references all use it
  - `:name` - a display name
  - `:api_key` - the API key: a string, `{:system, "ENV_VAR"}` or
    `{Module, :function, args}`, resolved on each request (see
    `resolve_auth/1`)
  - `:auth` - how the key is sent: `:bearer`, `{:header, name}`, `:none`, or
    `:dialect` (the default), which is the way the dialect's own API does it
  - `:headers` - extra headers sent with every request
  - `:dialects` - an `Omni.Provider.Endpoint` for each dialect module the
    provider serves
  - `:module` - the provider module, or `nil`

  ## How a provider is assembled

  Each provider selected in `config :omni, :models, providers: [...]` is
  built from three layers, later ones winning:

  1. **Source data.** The configured `Omni.Source` (the bundled models.dev
     catalog by default) gives the provider's name, its API key variable,
     an endpoint URL for each dialect its models speak, and the models.
  2. **The provider module**, if there is one. Its `c:config/0` overrides
     source values, and its other callbacks adjust models and requests.
     Every built-in has one.
  3. **App config**: the provider's entry in `config :omni, :providers`.

  A value in a later layer replaces the one before it, except that:

  - `:headers` merge by header name
  - `:dialects` merge by dialect module, then by field: `:base_url`
    replaces, and `:compat` merges flag by flag
  - `:models` merge by model id, then by field

  `:host` in app config moves the origin of every endpoint URL that came
  from the source or the module. A `:base_url` written in app config is
  used as written.

  Each model's dialect comes from the source, or from the module's
  `c:models/2`. Omni never fills one in. A catalog model with no dialect, or
  with a dialect the provider has no endpoint for, is skipped with a
  warning. A model from config in the same state raises.

  A provider that can't be assembled raises at boot: an unknown config key,
  an unknown compat flag, a `:host` that is more than an origin. A missing
  API key or endpoint URL does not, since a key can be passed with each
  request. A request to an endpoint with no URL returns
  `{:error, {:no_base_url, dialect}}`.

  ## Provider modules

  A provider module holds what config can't express. It declares
  `@behaviour Omni.Provider` and implements any of four optional callbacks:

  - `c:config/0` - config values, as a layer between the source and app
    config
  - `c:models/2` - changes the provider's models as they load
  - `c:modify_body/4` - changes a request body after the dialect builds it
  - `c:modify_request/3` - changes the finished request, for signing or
    fetching tokens

  ```elixir
  defmodule MyApp.DeepSeek do
    @behaviour Omni.Provider

    @impl true
    def modify_body(body, _model, %Omni.Context{}, _opts), do: Map.delete(body, "stream_options")
    def modify_body(body, _model, _decision, _opts), do: body
  end

  config :omni, :providers, deepseek: [module: MyApp.DeepSeek]
  ```

  Attach a module with `module:` in the provider's config. One module can
  serve several providers.

  Reach for compat flags first (see `Omni.Provider.Endpoint`). A module is
  for what flags can't say, such as a quirk only some of a provider's
  models have.

  ## Loading at runtime

  Providers load at boot. `load/1` loads more later:

  ```elixir
  Omni.Provider.load([:deepseek, gpu_box: [dialects: %{...}, models: [...]]])
  ```

  Loading an id that is already loaded replaces its provider and models.
  Models you already hold keep the provider struct they were built with.
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
  Returns config values, applied over source data when the provider loads.

  Takes `:name`, `:api_key`, `:auth`, `:headers` and `:dialects`, as in
  `config :omni, :providers`. App config overrides these values.

  ```elixir
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
  ```

  `compat: [like: :builtin_id]` copies a built-in's flags for that dialect.
  """
  @callback config() :: keyword()

  @doc """
  Changes the provider's models as they load.

  Receives the models from the source with config entries merged in, and
  the assembled provider. Returns the final list. The models do not yet
  hold the provider, and a config model may have no dialect yet, so this
  is where a module gives it one. A model still without a dialect
  afterwards is skipped if it came from the catalog, and raises if it came
  from config.

  ```elixir
  @impl true
  def models(models, _provider) do
    Enum.map(models, &%{&1 | input_modalities: Enum.uniq([:pdf | &1.input_modalities])})
  end
  ```
  """
  @callback models(models :: [Model.t()], provider :: t()) :: [Model.t()]

  @doc """
  Makes a last change to the finished request, after authentication.

  Use it to sign a request, fetch a token or rewrite the URL. Returns
  `{:ok, req}`, or `{:error, reason}` to fail the request, for example when
  credentials can't be found.
  """
  @callback modify_request(req :: Req.Request.t(), provider :: t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc """
  Adjusts the request body built by the dialect.

  For quirks compat flags can't express, typically ones that depend on the
  model. The body is the dialect's output, already shaped by any compat
  flags. The third argument is what is being sent, which tells you the
  capability: an `Omni.Context` for text generation, an `Omni.Decision` for
  a decision. Match on it to touch only one kind of request:

  ```elixir
  @impl true
  def modify_body(body, _model, %Omni.Context{}, _opts), do: Map.delete(body, "stream_options")
  def modify_body(body, _model, _decision, _opts), do: body
  ```
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

  ```elixir
  {:ok, provider} = Omni.Provider.get(:anthropic)
  provider.name  #=> "Anthropic"
  ```
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

  Each entry is a provider id, loaded with its `config :omni, :providers`
  entry, or `{id, opts}`, where `opts` are layered over that entry.

  ```elixir
  Omni.Provider.load([:deepseek])
  Omni.Provider.load(gpu_box: [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "http://gpu-box:8000/v1"]}])
  ```

  Raises `ArgumentError` when a provider can't be assembled (see
  [How a provider is assembled](#module-how-a-provider-is-assembled)).
  """
  @spec load([atom() | {atom(), keyword() | map()}]) :: :ok
  def load(entries) when is_list(entries), do: Omni.Provider.Loader.load(entries)

  @doc """
  Returns the ids of the built-in providers.
  """
  @spec builtins() :: [atom()]
  def builtins, do: Omni.Provider.Builtins.ids()

  @doc """
  Resolves an API key value to a string.

  - `"sk-..."` - a string, returned as it is
  - `{:system, "ENV_VAR"}` - read from the environment;
    `{:error, {:missing_env_var, name}}` when unset
  - `{Module, :function, args}` - the function's return value;
    `{:error, {:invalid_auth_value, value}}` when it isn't a string
  - `nil` - `{:error, :no_api_key}`
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

  ```elixir
  {:ok, provider} = Omni.Provider.get(:anthropic)
  {:ok, endpoint} = Omni.Provider.endpoint(provider, Omni.Dialects.AnthropicMessages)
  endpoint.base_url  #=> "https://api.anthropic.com/v1"
  ```
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
