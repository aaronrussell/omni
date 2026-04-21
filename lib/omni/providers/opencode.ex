defmodule Omni.Providers.OpenCode do
  @moduledoc """
  Provider for the OpenCode Zen API.

  Zen is a multi-model gateway that routes to different upstream APIs (Anthropic,
  OpenAI, Google, and others) through a single service. Unlike single-dialect
  providers, the wire format depends on the model — Claude models use the
  Anthropic Messages format, GPT models use OpenAI Responses, and so on. The
  correct dialect is resolved per-model from the data files.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :opencode]

  Or load it at runtime:

      Omni.Provider.load([:opencode])

  Reads the API key from the `OPENCODE_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.OpenCode,
        api_key: {:system, "MY_OPENCODE_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.
  """

  use Omni.Provider

  @impl true
  def config do
    %{
      base_url: "https://opencode.ai/zen",
      api_key: {:system, "OPENCODE_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/opencode.json")
  end

  @impl true
  def authenticate(req, opts) do
    with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
      {header, value} = auth_for_path(req.url.path, key)
      {:ok, Req.Request.put_header(req, header, value)}
    end
  end

  @impl true
  def build_url(path, opts) do
    opts.base_url <> String.replace(path, "/v1beta", "/v1")
  end

  # Zen mirrors each upstream API's auth scheme — the required header depends
  # on which dialect (and therefore which URL path) the model uses.
  defp auth_for_path("/zen/v1/messages" <> _, key), do: {"x-api-key", key}
  defp auth_for_path("/zen/v1/models" <> _, key), do: {"x-goog-api-key", key}
  defp auth_for_path(_path, key), do: {"authorization", "Bearer #{key}"}
end
