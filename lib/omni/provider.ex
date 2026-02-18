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
            auth_default: {:system, "ANTHROPIC_API_KEY"}
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

  - `load_models/2` — reads a JSON data file and builds `%Model{}` structs
  - `resolve_auth/1` — resolves API key values (literal, env var, MFA)
  - `stream/4` — makes an authenticated streaming HTTP request (stub)
  """

  alias Omni.Model

  @doc "Returns the provider's base configuration map."
  @callback config() :: map()

  @doc "Returns a Peri schema for provider-specific options."
  @callback option_schema() :: map()

  @doc "Returns the provider's list of model structs."
  @callback models() :: [Model.t()]

  @doc "Builds the full request URL from a base URL and path."
  @callback build_url(base_url :: String.t(), path :: String.t()) :: String.t()

  @doc "Adds authentication to a Req request."
  @callback authenticate(req :: Req.Request.t(), opts :: keyword()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @doc "Adapts a dialect-built request body for this provider."
  @callback adapt_body(body :: map(), opts :: keyword()) :: map()

  @doc "Adapts an SSE event map for this provider."
  @callback adapt_event(event :: map()) :: map()

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

  @doc """
  Makes an authenticated streaming HTTP request to a provider.

  Takes a provider module, a URL path, a request body map, and options.
  Currently returns `{:error, :not_implemented}` — full implementation
  will be added when the streaming infrastructure is built.
  """
  @spec stream(module(), String.t(), map(), keyword()) :: {:error, :not_implemented}
  def stream(_provider, _path, _body, _opts \\ []) do
    {:error, :not_implemented}
  end

  defmacro __using__(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    quote do
      @behaviour Omni.Provider

      @doc false
      def dialect, do: unquote(dialect)

      @impl Omni.Provider
      def option_schema, do: %{}

      @impl Omni.Provider
      def models, do: []

      @impl Omni.Provider
      def build_url(base_url, path), do: base_url <> path

      @impl Omni.Provider
      def authenticate(req, opts) do
        api_key = Keyword.get(opts, :api_key)

        with {:ok, key} <- Omni.Provider.resolve_auth(api_key) do
          header = Keyword.get(opts, :auth_header, "authorization")
          {:ok, Req.Request.put_header(req, header, key)}
        end
      end

      @impl Omni.Provider
      def adapt_body(body, _opts), do: body

      @impl Omni.Provider
      def adapt_event(event), do: event

      defoverridable option_schema: 0,
                     models: 0,
                     build_url: 2,
                     authenticate: 2,
                     adapt_body: 2,
                     adapt_event: 1
    end
  end
end
