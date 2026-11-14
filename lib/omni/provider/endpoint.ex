defmodule Omni.Provider.Endpoint do
  @moduledoc """
  Where a provider serves one dialect, and how it deviates from it.

  A provider's `:dialects` maps each dialect module it serves to an endpoint.
  `:base_url` is the whole URL of the API, version segment included, as API
  docs and SDKs mean it. A request goes to the base URL plus the dialect's
  resource path, and the dialect reads `:compat` while it encodes:

  ```elixir
  %Omni.Provider{
    id: :togetherai,
    dialects: %{
      Omni.Dialects.OpenAICompletions => %Omni.Provider.Endpoint{
        base_url: "https://api.together.ai/v1",
        compat: %{max_tokens_field: "max_tokens"}
      }
    }
  }

  # POST https://api.together.ai/v1/chat/completions
  ```

  Endpoints are assembled when the provider loads; configure them under
  `:dialects` (see `Omni.Provider`).
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
