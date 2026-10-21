defmodule Omni.Providers.OpenCode do
  @moduledoc """
  Provider for the OpenCode Zen API.

  Provider id `:opencode`. Reads the API key from `OPENCODE_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, opencode: [...]` (see `Omni.Provider`).

  Zen is a gateway to models from several labs through one service, and the
  wire format depends on the model: Claude models use
  `Omni.Dialects.AnthropicMessages`, GPT models use
  `Omni.Dialects.OpenAIResponses`, and so on. Each model's dialect comes from
  the catalog, and each request authenticates the way that dialect's home API
  does.

  Compat flags for this provider must be keyed by dialect (see
  `Omni.Provider`).
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://opencode.ai/zen/v1", api_key: {:system, "OPENCODE_API_KEY"}]
  end
end
