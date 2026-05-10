defmodule Omni.Providers.Venice do
  @moduledoc """
  Provider for the Venice AI API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :venice]

  Or load it at runtime:

      Omni.Provider.load([:venice])

  Reads the API key from the `VENICE_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Venice,
        api_key: {:system, "MY_VENICE_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## PDF input

  Every Venice model accepts PDF attachments — Venice extracts document text
  at the API layer regardless of the underlying model's native modalities.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.venice.ai/api",
      api_key: {:system, "VENICE_API_KEY"}
    }
  end

  @impl true
  def models do
    __MODULE__
    |> Omni.Provider.load_models("priv/models/venice.json")
    |> Enum.map(fn model ->
      case :pdf in model.input_modalities do
        true -> model
        false -> Map.update!(model, :input_modalities, &[:pdf | &1])
      end
    end)
  end

  @impl true
  def modify_body(body, _context, _opts) do
    disable_reasoning(body)
  end

  # Venice docs note that `reasoning_effort: "none"` has limited support and
  # recommend `reasoning: {enabled: false}` as the canonical disable form.
  defp disable_reasoning(%{"reasoning_effort" => "none"} = body) do
    body
    |> Map.put("reasoning", %{"enabled" => false})
    |> Map.delete("reasoning_effort")
  end

  defp disable_reasoning(body), do: body
end
