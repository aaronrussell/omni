defmodule Omni.Providers.Anthropic do
  @moduledoc """
  Provider for the Anthropic Messages API.

  Authenticates via the `x-api-key` header and includes the required
  `anthropic-version` header on every request.
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
