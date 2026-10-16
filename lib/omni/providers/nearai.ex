defmodule Omni.Providers.NearAI do
  @moduledoc """
  Provider for NEAR AI Cloud, including TEE-backed inference models, using the
  `Omni.Dialects.OpenAICompletions` dialect.

  Reads the API key from the `NEARAI_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        nearai: [api_key: {:system, "MY_NEARAI_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.
  """

  @behaviour Omni.Provider

  @impl true
  def config do
    [base_url: "https://cloud-api.near.ai/v1", api_key: {:system, "NEARAI_API_KEY"}]
  end

  @impl true
  def modify_body(body, _model, _context, _opts) do
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
