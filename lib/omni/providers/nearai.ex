defmodule Omni.Providers.NearAI do
  @moduledoc """
  Provider for NEAR AI Cloud, including TEE-backed inference models, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `NEARAI_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        nearai: [api_key: {:system, "MY_NEARAI_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Limitations

  The `:thinking` and `:cache` options are not sent, and structured output
  schemas are not marked strict.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://cloud-api.near.ai/v1",
      api_key: {:system, "NEARAI_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          max_tokens_field: "max_tokens",
          omit: [:cache, :thinking, :strict_schema]
        ]
      }
    ]
  end
end
