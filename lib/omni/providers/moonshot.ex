defmodule Omni.Providers.Moonshot do
  @moduledoc """
  Provider for the Moonshot AI (Kimi) API, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `MOONSHOT_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        moonshotai: [api_key: {:system, "MY_MOONSHOT_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Reasoning

  The `:thinking` option is supported. Moonshot exposes no effort
  granularity — all positive levels (`:low` through `:max`) enable
  reasoning equally.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://api.moonshot.ai/v1", api_key: {:system, "MOONSHOT_API_KEY"}]
  end

  @impl true
  def modify_body(body, _model, _context, _opts) do
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
