defmodule Omni.Provider do
  @moduledoc """
  Behaviour and shared logic for LLM providers.

  A provider represents a specific LLM service — its endpoint, authentication
  mechanism, and any service-specific adaptations. It is the authenticated HTTP
  layer: it knows *where* to send requests and *how* to authenticate them, but
  not *what* the request body should contain (that's the dialect's job).

  ## Defining a provider

  Use `use Omni.Provider` with a required `:dialect` option:

      defmodule Omni.Providers.Anthropic do
        use Omni.Provider, dialect: Omni.Dialects.AnthropicMessages

        @impl true
        def config do
          %{
            base_url: "https://api.anthropic.com",
            auth_header: "x-api-key",
            api_key: {:system, "ANTHROPIC_API_KEY"}
          }
        end

        @impl true
        def models do
          Omni.Provider.load_models(__MODULE__, "priv/models/anthropic.json")
        end
      end

  The macro generates a `dialect/0` accessor and sensible defaults for all
  optional callbacks. Override only what your provider needs.

  ## Shared functions

  - `load/1` — loads providers' models into `:persistent_term` on demand
  - `load_models/2` — reads a JSON data file and builds `%Model{}` structs
  - `resolve_auth/1` — resolves API key values (literal, env var, MFA)
  """

  alias Omni.Model

  @builtin_providers %{
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    openai: Omni.Providers.OpenAI,
    openrouter: Omni.Providers.OpenRouter
  }

  @doc "Returns the provider's base configuration map."
  @callback config() :: map()

  @doc "Returns the provider's list of model structs."
  @callback models() :: [Model.t()]

  @doc "Builds the full request URL from a path and unified opts map."
  @callback build_url(path :: String.t(), opts :: map()) :: String.t()

  @doc "Adds authentication to a Req request."
  @callback authenticate(req :: Req.Request.t(), opts :: map()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc "Modifies a dialect-built request body for this provider."
  @callback modify_body(body :: map(), opts :: map()) :: map()

  @doc "Post-dialect event modification. Receives parsed deltas and the raw SSE event."
  @callback modify_events(deltas :: [{atom(), map()}], raw_event :: map()) :: [{atom(), map()}]

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
    {:ok, apply(mod, fun, args)}
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
      model_map = Map.new(mod.models(), &{&1.id, &1})
      existing = :persistent_term.get({Omni, id}, %{})
      :persistent_term.put({Omni, id}, Map.merge(existing, model_map))
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

  Each model is stamped with the given provider module and its dialect.
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
    Model.new(
      id: data["id"],
      name: data["name"],
      provider: module,
      dialect: module.dialect(),
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

  defmacro __using__(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

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
end
