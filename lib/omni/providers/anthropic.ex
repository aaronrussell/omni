defmodule Omni.Providers.Anthropic do
  @moduledoc """
  Provider for the Anthropic API, using the `Omni.Dialects.AnthropicMessages`
  dialect.

  Loaded by default. Reads the API key from the `ANTHROPIC_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.anthropic.com/v1",
      api_key: {:system, "ANTHROPIC_API_KEY"},
      headers: %{"anthropic-version" => "2023-06-01"}
    ]
  end
end
