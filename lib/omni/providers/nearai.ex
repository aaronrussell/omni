defmodule Omni.Providers.NearAI do
  @moduledoc false

  # The built-in `:nearai` provider: NEAR AI Cloud, over Chat Completions.
  #
  # The catalog's decision models load over `Omni.Dialects.TypeSafeSystemOne` at
  # the catalog's URL, so no endpoint is set for it here. NEAR AI doesn't
  # document that endpoint, and it hasn't been verified against the live API.
  #
  # Users read about it in the "NEAR AI Cloud" section of
  # guides/built-in-providers.md. Keep that in step with this module.

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
