defmodule Omni.Providers.Moonshot do
  @moduledoc """
  Provider for the Moonshot AI (Kimi) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :moonshot]

  Or load it at runtime:

      Omni.Provider.load([:moonshot])

  Reads the API key from the `MOONSHOT_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Moonshot,
        api_key: {:system, "MY_MOONSHOT_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Reasoning

  Moonshot's Kimi models don't accept the standard `reasoning_effort`
  parameter. Instead, reasoning is toggled via a `thinking` object:
  `%{"type" => "enabled"}` or `%{"type" => "disabled"}`. This provider
  translates the standard `:thinking` option:

    * `thinking: false` → `thinking: %{"type" => "disabled"}`
    * Any other level (`:low`, `:medium`, `:high`, `:xhigh`, `:max`) →
      `thinking: %{"type" => "enabled"}`

  Effort levels are flattened to on/off because Moonshot exposes no
  granularity. Reasoning content streams back as `reasoning_content`, which
  the Completions dialect already parses into thinking blocks.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.moonshot.ai",
      api_key: {:system, "MOONSHOT_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/moonshotai.json")
  end

  @impl true
  def modify_body(body, _context, _opts) do
    normalize_reasoning_effort(body)
  end

  defp normalize_reasoning_effort(%{"reasoning_effort" => "none"} = body) do
    body
    |> Map.put("thinking", %{"type" => "disabled"})
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(%{"reasoning_effort" => _} = body) do
    body
    |> Map.put("thinking", %{"type" => "enabled"})
    |> Map.delete("reasoning_effort")
  end

  defp normalize_reasoning_effort(body), do: body
end
