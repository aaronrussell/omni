defmodule Omni.Providers.Anthropic do
  @moduledoc false

  # Provider for the Anthropic API, using the `Omni.Dialects.AnthropicMessages`
  # dialect.
  #
  # Sends the `anthropic-version: 2023-06-01` header on every request.
  #
  # What users are told is the "Anthropic" section of
  # guides/built-in-providers.md; keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "ANTHROPIC_API_KEY"},
      headers: %{"anthropic-version" => "2023-06-01"},
      dialects: %{Omni.Dialects.AnthropicMessages => [base_url: "https://api.anthropic.com/v1"]}
    ]
  end
end
