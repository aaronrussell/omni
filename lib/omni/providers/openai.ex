defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect.

  Loaded by default. Reads the API key from the `OPENAI_API_KEY` environment
  variable — no configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.OpenAI,
        api_key: {:system, "MY_OPENAI_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAIResponses

  @impl true
  def config do
    %{
      base_url: "https://api.openai.com",
      api_key: {:system, "OPENAI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/openai.json")
  end

end
