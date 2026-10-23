defmodule Omni.Providers.Moonshot do
  @moduledoc """
  Provider for the Moonshot AI (Kimi) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Provider id `:moonshotai`. Reads the API key from `MOONSHOT_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, moonshotai: [...]` (see `Omni.Provider`).

  The catalog lists the China endpoint as its own provider, `:moonshotai_cn`;
  `compat: [like: :moonshotai]` gives it these flags.

  ## Reasoning

  `:thinking` is supported. Models that take effort levels get the nearest
  level the model supports; the rest switch thinking on and off with
  `thinking: {type: "enabled" | "disabled"}`.

  ## Limitations

  Kimi K2.6 ignores the `:output` schema while thinking, which is on by
  default, and answers in prose. Pass `thinking: false` with `:output`. Kimi
  K2.7 and K3 follow the schema with thinking on.

  ## Compat flags

  Sets this `Omni.Dialects.OpenAICompletions` flag:

    * `thinking_toggle_format: :thinking_type`
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      base_url: "https://api.moonshot.ai/v1",
      api_key: {:system, "MOONSHOT_API_KEY"},
      compat: %{
        Omni.Dialects.OpenAICompletions => [
          thinking_toggle_format: :thinking_type
        ]
      }
    ]
  end
end
