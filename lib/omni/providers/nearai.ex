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

  ## Decisions

  The catalog's decision models (`typesafe/jev-1.13`, `levanto/sage-1.4`)
  load over `Omni.Dialects.SystemOne`, at the provider's catalog URL. NEAR AI
  doesn't document this endpoint, and it hasn't been verified against the
  live API.

  ## Compat flags

  Sets these `Omni.Dialects.OpenAICompletions` flags:

    * `max_tokens_field: "max_tokens"`
    * `omit: [:cache, :thinking, :strict_schema]`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "NEARAI_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://cloud-api.near.ai/v1",
          compat: [max_tokens_field: "max_tokens", omit: [:cache, :thinking, :strict_schema]]
        ]
      }
    ]
  end
end
