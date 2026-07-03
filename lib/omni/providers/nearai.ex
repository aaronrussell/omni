defmodule Omni.Providers.NearAI do
  @moduledoc """
  Provider for NEAR AI Cloud, including TEE-backed inference models, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `NEARAI_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.NearAI,
        api_key: {:system, "MY_NEARAI_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  ## Compatibility

  NEAR AI Cloud exposes an OpenAI-compatible API at
  `https://cloud-api.near.ai/v1`. Omni stores provider `:base_url` values
  without the dialect path prefix, so the configured service root is
  `https://cloud-api.near.ai`.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://cloud-api.near.ai",
      api_key: {:system, "NEARAI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__)
  end

  @impl true
  def modify_body(body, _context, _opts) do
    body
    |> normalize_max_tokens()
    |> drop_unsupported_fields()
    |> drop_strict_json_schema()
  end

  defp normalize_max_tokens(%{"max_completion_tokens" => tokens} = body) do
    body
    |> Map.delete("max_completion_tokens")
    |> Map.put_new("max_tokens", tokens)
  end

  defp normalize_max_tokens(body), do: body

  defp drop_unsupported_fields(body) do
    Map.drop(body, ["prompt_cache_retention", "reasoning_effort", "store"])
  end

  defp drop_strict_json_schema(
         %{"response_format" => %{"json_schema" => json_schema} = response_format} = body
       )
       when is_map(json_schema) do
    response_format = Map.put(response_format, "json_schema", Map.delete(json_schema, "strict"))
    Map.put(body, "response_format", response_format)
  end

  defp drop_strict_json_schema(body), do: body
end
