defmodule Omni.Providers.Anthropic do
  @moduledoc """
  Provider for the Anthropic API, using the `Omni.Dialects.AnthropicMessages`
  dialect.

  Loaded by default. Reads the API key from the `ANTHROPIC_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Anthropic,
        api_key: {:system, "MY_ANTHROPIC_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`, `:headers`. See `Omni.Provider` for details.
  """

  use Omni.Provider, dialect: Omni.Dialects.AnthropicMessages

  @impl true
  def config do
    %{
      base_url: "https://api.anthropic.com",
      auth_header: "x-api-key",
      api_key: {:system, "ANTHROPIC_API_KEY"},
      headers: %{"anthropic-version" => "2023-06-01"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/anthropic.json")
  end
end
