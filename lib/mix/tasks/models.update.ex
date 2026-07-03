defmodule Mix.Tasks.Models.Update do
  @shortdoc "Fetches model data from models.dev"

  @moduledoc """
  Fetches model catalog data from models.dev and writes JSON files to `priv/models/`.

      mix models.update

  Each supported provider gets a JSON file containing an array of model objects
  with fields matching the `Omni.Model` struct: `id`, `name`, `reasoning`,
  `release_date`, `dialect`, `input_modalities`, `output_modalities`,
  `input_cost`, `output_cost`, `cache_read_cost`, `cache_write_cost`,
  `context_size`, and `max_output_tokens`.

  The `dialect` field is a string identifier (e.g. `"anthropic_messages"`,
  `"openai_responses"`) inferred from the models.dev npm package metadata.
  It is resolved to a module by `Omni.Dialect.get!/1` at load time and takes
  priority over the provider's declared dialect, which serves only as a
  fallback for entries without the field.

  Models that are deprecated or lack tool use support are filtered out. Modalities
  are filtered to those Omni supports (input: text, image, pdf; output: text).
  Output is sorted by `id` for stable diffs.
  """
  require Logger

  use Mix.Task

  @api_url "https://models.dev/api.json"
  @output_dir "priv/models"

  @builtin_providers Enum.sort(Omni.Provider.builtin_providers())
  @supported_input_modalities Enum.map(Omni.Model.supported_modalities(:input), &to_string/1)
  @supported_output_modalities Enum.map(Omni.Model.supported_modalities(:output), &to_string/1)

  @npm_to_dialect %{
    "@ai-sdk/alibaba" => "openai_completions",
    "@ai-sdk/anthropic" => "anthropic_messages",
    "@ai-sdk/google" => "google_gemini",
    "@ai-sdk/groq" => "openai_completions",
    "@ai-sdk/openai" => "openai_responses",
    "@ai-sdk/openai-compatible" => "openai_completions",
    "@openrouter/ai-sdk-provider" => "openai_completions",
    "venice-ai-sdk-provider" => "openai_completions"
  }

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    data = fetch_api()

    File.mkdir_p!(@output_dir)

    for {provider_id, _provider_mod} <- @builtin_providers do
      case Map.fetch(data, provider_string(provider_id)) do
        {:ok, provider_data} ->
          models =
            provider_data
            |> get_models()
            |> Enum.reject(&(&1["status"] == "deprecated"))
            |> Enum.filter(&(&1["tool_call"] == true and text_model?(&1)))
            |> Enum.map(&transform_model(&1, provider_id, provider_data))
            |> Enum.reject(&is_nil(&1["dialect"]))
            |> Enum.sort_by(& &1["id"])

          file = Path.join(@output_dir, "#{provider_id}.json")
          json = Jason.encode!(models, pretty: true)
          File.write!(file, json <> "\n")

          Mix.shell().info("#{provider_id}: wrote #{length(models)} models to #{file}")

        :error ->
          Mix.raise("Provider #{inspect(provider_id)} not found in API response")
      end
    end
  end

  # Omni -> models.dev provider id mapping
  defp provider_string(:moonshot), do: "moonshotai"
  defp provider_string(:ollama), do: "ollama-cloud"
  defp provider_string(provider_id), do: to_string(provider_id)

  defp transform_model(
         %{"limit" => limit, "modalities" => modalities} = model,
         provider_id,
         provider_data
       ) do
    cost = model["cost"] || %{}
    npm = get_in(model, ["provider", "npm"]) || provider_data["npm"]

    %{
      "id" => model["id"],
      "name" => model["name"],
      "reasoning" => model["reasoning"] || false,
      "release_date" => model["release_date"],
      "dialect" => derive_dialect(npm, "#{provider_id}:#{model["id"]}"),
      "input_modalities" => filter_modalities(modalities["input"], @supported_input_modalities),
      "output_modalities" =>
        filter_modalities(modalities["output"], @supported_output_modalities),
      "input_cost" => cost["input"] || 0,
      "output_cost" => cost["output"] || 0,
      "cache_read_cost" => cost["cache_read"] || 0,
      "cache_write_cost" => cost["cache_write"] || 0,
      "context_size" => limit["context"] || 0,
      "max_output_tokens" => limit["output"] || 0
    }
  end

  defp derive_dialect(npm, ref) do
    if is_nil(@npm_to_dialect[npm]) do
      Logger.warning("Unknown dialect: #{ref} [npm=#{npm}]")
    end

    @npm_to_dialect[npm]
  end

  defp fetch_api do
    case Req.get(@api_url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status}} ->
        Mix.raise("models.dev returned HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Failed to fetch models.dev: #{inspect(reason)}")
    end
  end

  defp filter_modalities(nil, _supported), do: []

  defp filter_modalities(modalities, supported) do
    Enum.filter(modalities, &(&1 in supported))
  end

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  defp text_model?(%{"modalities" => modalities}) do
    "text" in modalities["input"] and "text" in modalities["output"]
  end
end
