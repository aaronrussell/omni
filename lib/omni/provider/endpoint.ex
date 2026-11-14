defmodule Omni.Provider.Endpoint do
  @moduledoc """
  Where a provider serves one dialect, and how it deviates from it.

  A provider's `:dialects` maps each dialect module it serves to an
  endpoint. A gateway that serves several dialects has one for each, on
  whatever path or host it uses.

  ```elixir
  {:ok, provider} = Omni.get_provider(:deepseek)

  provider.dialects
  #=> %{
  #     Omni.Dialects.OpenAICompletions => %Omni.Provider.Endpoint{
  #       base_url: "https://api.deepseek.com",
  #       compat: %{}
  #     }
  #   }
  ```

  Endpoints are assembled when the provider loads. You set them under
  `:dialects` in the provider's config, as a keyword list for each dialect:

  ```elixir
  config :omni, :providers,
    gpu_box: [
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "http://gpu-box:8000/v1",
          compat: [max_tokens_field: "max_tokens"]
        ]
      }
    ]
  ```

  An empty list, `Module => []`, declares that the provider serves the
  dialect and leaves the URL to the catalog or the provider module.

  ## Struct fields

  - `:base_url` - the whole URL of the API, version segment included, as
    API docs and SDKs give it. A request goes to this plus the dialect's
    resource path: `http://gpu-box:8000/v1` plus `/chat/completions`
  - `:compat` - a map of compat flags, which the dialect reads as it
    encodes a request

  ## URLs

  A request's URL can be set in three places:

  | Where | Sets | When |
  | --- | --- | --- |
  | `base_url:` on the endpoint | that endpoint's whole URL | load |
  | `host:` on the provider | the origin of every endpoint URL from the catalog or the provider module | load |
  | the `host:` request option | the origin of that request's URL | request |

  `host:` is an origin only (scheme, host and port) and keeps each URL's
  path: `ollama: [host: "http://gpu:11434"]` sends chat to
  `http://gpu:11434/api/chat`. It suits another machine, a region, or a
  proxy on the same paths. It also fills in a catalog URL whose origin is a
  placeholder, such as `https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1`.

  A `base_url:` in app config is used as written, and the provider's
  `host:` does not move it. The `host:` request option moves any URL. To
  change a path, set `base_url:`.

  ## Compat flags

  A compat flag describes one way a provider differs from the API its
  dialect is named after. Each dialect's moduledoc lists the flags it
  understands (see `Omni.Dialects.OpenAICompletions`), and an unknown flag
  is an error at boot. A flag left out means the provider behaves as the
  dialect's own API does.

  `like:` copies a built-in provider's flags for the same dialect, which
  suits a catalog provider that is a built-in under another name:

  ```elixir
  config :omni, :providers,
    zai_coding_plan: [dialects: %{Omni.Dialects.OpenAICompletions => [compat: [like: :zai]]}]
  ```

  Flags written beside `like:` are layered over the copied ones. Flags you
  set on a built-in merge over its own one at a time, so setting one leaves
  the rest in place.
  """

  defstruct base_url: nil, compat: %{}

  @typedoc "A provider's endpoint for one dialect."
  @type t :: %__MODULE__{base_url: String.t() | nil, compat: map()}

  @doc false
  # A host is an origin: scheme, host and optional port, nothing after.
  @spec validate_host(term()) :: :ok | {:error, {:invalid_host, term()}}
  def validate_host(host) when is_binary(host) do
    case URI.new(host) do
      {:ok, %URI{scheme: scheme, host: h, path: path, query: nil, fragment: nil, userinfo: nil}}
      when is_binary(scheme) and is_binary(h) and h != "" and path in [nil, "", "/"] ->
        :ok

      _ ->
        {:error, {:invalid_host, host}}
    end
  end

  def validate_host(host), do: {:error, {:invalid_host, host}}

  @doc false
  # Replaces the origin of `url` with `host`, keeping the path. The origin is
  # `scheme://authority`, or a leading `${VAR}` / `{var}` placeholder for a
  # templated URL with no scheme.
  @spec put_host(String.t() | nil, String.t()) :: String.t() | nil
  def put_host(nil, _host), do: nil

  def put_host(url, host) when is_binary(url) and is_binary(host) do
    {_origin, path} = split(url)
    String.trim_trailing(host, "/") <> path
  end

  @doc false
  # Splits a URL into its origin and the rest, as put_host/2 sees them.
  @spec split(String.t()) :: {String.t(), String.t()}
  def split(url) when is_binary(url) do
    case Regex.run(~r"\A([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*|\$\{[^}]*\}|\{[^}]*\})(.*)\z"s, url) do
      [_, origin, path] -> {origin, path}
      nil -> {"", url}
    end
  end

  @doc false
  # A URL still holding a catalog placeholder can't be sent.
  @spec placeholder?(String.t()) :: boolean()
  def placeholder?(url), do: String.contains?(url, "${") or Regex.match?(~r/\{[^}]*\}/, url)
end
