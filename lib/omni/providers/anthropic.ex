defmodule Omni.Providers.Anthropic do
  @moduledoc """
  Provider for the Anthropic API, using the `Omni.Dialects.AnthropicMessages`
  dialect.

  Provider id `:anthropic`. Reads the API key from `ANTHROPIC_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, anthropic: [...]` (see `Omni.Provider`).

  Sends the `anthropic-version: 2023-06-01` header on every request.
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
