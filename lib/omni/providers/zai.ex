defmodule Omni.Providers.Zai do
  @moduledoc """
  Provider for the Z.ai API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :zai]

  Or load it at runtime:

      Omni.Provider.load([:zai])

  Reads the API key from the `ZAI_API_KEY` environment variable — no further
  configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Zai,
        api_key: {:system, "MY_ZAI_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Endpoint version

  Z.ai serves the OpenAI Completions wire format under `/v4/` rather than the
  conventional `/v1/`. `build_url/2` rewrites the dialect's path so callers
  don't need to think about it.

  ## Reasoning

  Z.ai's GLM models all support reasoning, but they don't accept the standard
  `reasoning_effort` parameter. Instead, reasoning is toggled via a `thinking`
  object: `%{"type" => "enabled"}` or `%{"type" => "disabled"}`. This provider
  translates the standard `:thinking` option:

    * `thinking: false` → `thinking: %{"type" => "disabled"}`
    * Any other level (`:low`, `:medium`, `:high`, `:xhigh`, `:max`) →
      `thinking: %{"type" => "enabled"}`

  Effort levels are flattened to on/off because Z.ai exposes no granularity —
  reasoning is either on or it isn't. Reasoning content streams back as
  `reasoning_content`, which the Completions dialect already parses into
  thinking blocks.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.z.ai/api/paas",
      api_key: {:system, "ZAI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/zai.json")
  end

  @impl true
  def build_url(path, opts) do
    opts.base_url <> String.replace(path, "/v1", "/v4")
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
