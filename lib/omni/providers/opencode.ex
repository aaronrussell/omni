defmodule Omni.Providers.OpenCode do
  @moduledoc """
  Provider for the OpenCode Zen API.

  Zen is a multi-model gateway that routes to different upstream APIs (Anthropic,
  OpenAI, Google, and others) through a single service. Unlike single-dialect
  providers, the wire format depends on the model — Claude models use the
  Anthropic Messages format, GPT models use OpenAI Responses, and so on. The
  correct dialect is resolved per-model from the catalog data, and each
  request authenticates the way that dialect's upstream API does.

  Reads the API key from the `OPENCODE_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        opencode: [api_key: {:system, "MY_OPENCODE_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://opencode.ai/zen/v1", api_key: {:system, "OPENCODE_API_KEY"}]
  end
end
