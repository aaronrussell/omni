defmodule Mix.Tasks.Models.Get do
  @shortdoc "Fetches model catalog data"

  @moduledoc """
  Fetches model catalog data and writes JSON files to `priv/models/`.

      mix models.get

  Most providers are sourced from models.dev. NEAR AI Cloud is sourced from its
  public model list endpoint. Each supported provider gets a JSON file
  containing an array of model objects with fields matching the `Omni.Model`
  struct: `id`, `name`, `reasoning`, `release_date`, `dialect`,
  `input_modalities`, `output_modalities`, `input_cost`, `output_cost`,
  `cache_read_cost`, `cache_write_cost`, `context_size`, and
  `max_output_tokens`.

  The `dialect` field is a string identifier (e.g. `"anthropic_messages"`,
  `"openai_responses"`) inferred from the models.dev npm package metadata.
  It is resolved to a module by `Omni.Dialect.get!/1` at load time. For
  single-dialect providers the field is present but ignored — the provider's
  declared dialect takes priority.

  Models that are deprecated or lack tool use support are filtered out. Modalities
  are filtered to those Omni supports (input: text, image, pdf; output: text).
  Output is sorted by `id` for stable diffs.
  """

  use Mix.Task

  @api_url "https://models.dev/api.json"
  @nearai_api_url "https://cloud-api.near.ai/v1/model/list"
  @output_dir "priv/models"
  @models_dev_providers [
    "alibaba",
    "anthropic",
    "google",
    "groq",
    "moonshotai",
    "ollama-cloud",
    "openai",
    "opencode",
    "openrouter",
    "venice",
    "zai"
  ]
  @supported_input_modalities Enum.map(Omni.Model.supported_modalities(:input), &to_string/1)
  @supported_output_modalities Enum.map(Omni.Model.supported_modalities(:output), &to_string/1)

  @npm_to_dialect %{
    "@ai-sdk/anthropic" => "anthropic_messages",
    "@ai-sdk/openai" => "openai_responses",
    "@ai-sdk/openai-compatible" => "openai_completions",
    "@ai-sdk/alibaba" => "openai_completions",
    "@ai-sdk/google" => "google_gemini"
  }

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    data = fetch_api()

    File.mkdir_p!(@output_dir)

    for provider_id <- @models_dev_providers do
      case Map.fetch(data, provider_id) do
        {:ok, provider_data} ->
          provider_npm = provider_data["npm"]

          models =
            provider_data
            |> get_models()
            |> Enum.reject(&skip?/1)
            |> Enum.map(&transform_model(&1, provider_npm))
            |> Enum.filter(&("text" in &1["input_modalities"]))
            |> Enum.sort_by(& &1["id"])

          write_models(provider_id, models)

        :error ->
          Mix.raise("Provider #{inspect(provider_id)} not found in API response")
      end
    end

    nearai_models =
      fetch_nearai_api()
      |> get_nearai_models()
      |> Enum.reject(&skip_nearai?/1)
      |> Enum.map(&transform_nearai_model/1)
      |> Enum.sort_by(& &1["id"])

    write_models("nearai", nearai_models)
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

  defp fetch_nearai_api do
    case Req.get(@nearai_api_url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status}} ->
        Mix.raise("NEAR AI Cloud model list returned HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Failed to fetch NEAR AI Cloud model list: #{inspect(reason)}")
    end
  end

  defp write_models(provider_id, models) do
    file = Path.join(@output_dir, "#{provider_id}.json")
    json = Jason.encode!(models, pretty: true)
    File.write!(file, json <> "\n")

    Mix.shell().info("#{provider_id}: wrote #{length(models)} models to #{file}")
  end

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  defp get_nearai_models(%{"models" => models}) when is_list(models), do: models
  defp get_nearai_models(_), do: []

  defp skip?(%{"status" => "deprecated"}), do: true
  defp skip?(%{"tool_call" => false}), do: true
  defp skip?(%{"tool_call" => nil}), do: true
  defp skip?(model), do: not Map.has_key?(model, "tool_call")

  defp skip_nearai?(%{"modelId" => id, "metadata" => metadata})
       when is_binary(id) and is_map(metadata) do
    architecture = metadata["architecture"] || %{}
    input_modalities = architecture["inputModalities"] || []
    output_modalities = architecture["outputModalities"] || []
    downcased_id = String.downcase(id)

    "text" not in input_modalities or
      "text" not in output_modalities or
      String.contains?(downcased_id, "privacy-filter") or
      String.contains?(downcased_id, "reranker")
  end

  defp skip_nearai?(_model), do: true

  defp filter_modalities(nil, _supported), do: []

  defp filter_modalities(modalities, supported) do
    Enum.filter(modalities, &(&1 in supported))
  end

  defp transform_model(model, provider_npm) do
    npm = get_in(model, ["provider", "npm"]) || provider_npm
    dialect = @npm_to_dialect[npm]

    %{
      "id" => model["id"],
      "name" => model["name"],
      "reasoning" => model["reasoning"] || false,
      "release_date" => model["release_date"],
      "dialect" => dialect,
      "input_modalities" =>
        filter_modalities(get_in(model, ["modalities", "input"]), @supported_input_modalities),
      "output_modalities" =>
        filter_modalities(get_in(model, ["modalities", "output"]), @supported_output_modalities),
      "input_cost" => get_in(model, ["cost", "input"]) || 0,
      "output_cost" => get_in(model, ["cost", "output"]) || 0,
      "cache_read_cost" => get_in(model, ["cost", "cache_read"]) || 0,
      "cache_write_cost" => get_in(model, ["cost", "cache_write"]) || 0,
      "context_size" => get_in(model, ["limit", "context"]) || 0,
      "max_output_tokens" => get_in(model, ["limit", "output"]) || 0
    }
  end

  defp transform_nearai_model(%{"modelId" => id, "metadata" => metadata} = model) do
    architecture = metadata["architecture"] || %{}

    %{
      "id" => id,
      "name" => metadata["modelDisplayName"] || id,
      "reasoning" => false,
      "release_date" => nil,
      "dialect" => "openai_completions",
      "input_modalities" =>
        filter_modalities(architecture["inputModalities"] || [], @supported_input_modalities),
      "output_modalities" =>
        filter_modalities(architecture["outputModalities"] || [], @supported_output_modalities),
      "input_cost" => nearai_cost(model["inputCostPerToken"]),
      "output_cost" => nearai_cost(model["outputCostPerToken"]),
      "cache_read_cost" => nearai_cost(model["cacheReadCostPerToken"]),
      "cache_write_cost" => 0,
      "context_size" => metadata["contextLength"] || 0,
      "max_output_tokens" => 0
    }
  end

  defp nearai_cost(%{"amount" => amount, "scale" => scale})
       when is_number(amount) and is_integer(scale) do
    multiplier = :math.pow(10, 6 - scale)
    normalize_cost(amount * multiplier)
  end

  defp nearai_cost(_), do: 0

  defp normalize_cost(value) when is_float(value) do
    rounded = Float.round(value, 12)

    if rounded == trunc(rounded) do
      trunc(rounded)
    else
      rounded
    end
  end

  defp normalize_cost(value), do: value
end
