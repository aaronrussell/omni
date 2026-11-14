defmodule Omni.Providers.Anthropic do
  @moduledoc false

  # The built-in `:anthropic` provider: the Anthropic API, over Messages.
  #
  # Sends the `anthropic-version` header on every request.
  #
  # Users read about it in the "Anthropic" section of
  # guides/built-in-providers.md. Keep that in step with this module.

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
