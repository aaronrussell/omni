defmodule Omni.Providers.NearAI do
  @moduledoc false

  # Provider for NEAR AI Cloud, including TEE-backed inference models, using the
  # `Omni.Dialects.OpenAICompletions` dialect.
  #
  # Limitations:
  #
  # The `:thinking` and `:cache` options are not sent, and structured output
  # schemas are not marked strict.
  #
  # Decisions:
  #
  # The catalog's decision models (`typesafe/jev-1.13`, `levanto/sage-1.4`)
  # load over `Omni.Dialects.TypeSafeSystemOne`, at the provider's catalog URL. NEAR AI
  # doesn't document this endpoint, and it hasn't been verified against the
  # live API.
  #
  # What users are told is the "NEAR AI Cloud" section of
  # guides/built-in-providers.md; keep it in step with this module.

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
