defmodule Omni.Providers.Groq do
  @moduledoc """
  Provider for the Groq API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :groq]

  Or load it at runtime:

      Omni.Provider.load([:groq])

  Reads the API key from the `GROQ_API_KEY` environment variable — no further
  configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.Groq,
        api_key: {:system, "MY_GROQ_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Reasoning

  The `:thinking` option is supported. Accepted effort levels vary by model
  family — this provider normalises values so the standard option works
  across all Groq-hosted reasoning models. In practice, `:xhigh` and `:max`
  may be clamped to the model's maximum supported level.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.groq.com/openai",
      api_key: {:system, "GROQ_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/groq.json")
  end

  @impl true
  def modify_body(body, _context, _opts) do
    normalize_reasoning_effort(body)
  end

  # GPT-OSS rejects xhigh and max; clamp to the model's max ("high")
  defp normalize_reasoning_effort(
         %{"reasoning_effort" => effort, "model" => "openai/gpt-oss" <> _} = body
       )
       when effort in ["xhigh", "max"] do
    body
    |> Map.put("reasoning_effort", "high")
    |> Map.put("reasoning_format", "parsed")
  end

  # Qwen only accepts "none" or "default", so any positive level becomes "default"
  defp normalize_reasoning_effort(
         %{"reasoning_effort" => effort, "model" => "qwen/qwen3-32b"} = body
       )
       when effort in ["low", "medium", "high", "xhigh"] do
    body
    |> Map.put("reasoning_effort", "default")
    |> Map.put("reasoning_format", "parsed")
  end

  defp normalize_reasoning_effort(body), do: body
end
