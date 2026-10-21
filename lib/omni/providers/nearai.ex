defmodule Omni.Providers.NearAI do
  @moduledoc """
  Provider for NEAR AI Cloud, including TEE-backed inference models, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Provider id `:nearai`. Reads the API key from `NEARAI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, nearai: [...]` (see `Omni.Provider`).

  ## Limitations

  The `:thinking` and `:cache` options are not sent, and structured output
  schemas are not marked strict.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `max_tokens_field: "max_tokens"`
    * `omit: [:cache, :thinking, :strict_schema]`
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
