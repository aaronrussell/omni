defmodule Mix.Tasks.Models.Get do
  @shortdoc "Fetches model data from models.dev"

  @moduledoc """
  Fetches model catalog data from models.dev and writes JSON files to `priv/models/`.

      mix models.get

  Each supported provider gets a JSON file containing an array of model objects
  with fields matching the `Omni.Model` struct: `id`, `name`, `reasoning`,
  `input_modalities`, `output_modalities`, `input_cost`, `output_cost`,
  `cache_read_cost`, `cache_write_cost`, `context_size`, and `max_output_tokens`.

  Models that are deprecated or lack tool use support are filtered out. Modalities
  are filtered to those Omni supports (input: text, image, pdf; output: text).
  Output is sorted by `id` for stable diffs.
  """

  use Mix.Task

  @api_url "https://models.dev/api.json"
  @output_dir "priv/models"
  @providers ["anthropic", "google", "openai"]
  @supported_input_modalities Enum.map(Omni.Model.supported_input_modalities(), &to_string/1)
  @supported_output_modalities Enum.map(Omni.Model.supported_output_modalities(), &to_string/1)

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    data = fetch_api()

    File.mkdir_p!(@output_dir)

    for provider_id <- @providers do
      case Map.fetch(data, provider_id) do
        {:ok, provider_data} ->
          models =
            provider_data
            |> get_models()
            |> Enum.reject(&skip?/1)
            |> Enum.map(&transform_model/1)
            |> Enum.filter(&("text" in &1["input_modalities"]))
            |> Enum.sort_by(& &1["id"])

          path = Path.join(@output_dir, "#{provider_id}.json")
          json = Jason.encode!(models, pretty: true)
          File.write!(path, json <> "\n")

          Mix.shell().info("#{provider_id}: wrote #{length(models)} models to #{path}")

        :error ->
          Mix.raise("Provider #{inspect(provider_id)} not found in API response")
      end
    end
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

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  defp skip?(%{"status" => "deprecated"}), do: true
  defp skip?(%{"tool_call" => false}), do: true
  defp skip?(%{"tool_call" => nil}), do: true
  defp skip?(model), do: not Map.has_key?(model, "tool_call")

  defp filter_modalities(nil, supported), do: Enum.take(supported, 1)

  defp filter_modalities(modalities, supported) do
    case Enum.filter(modalities, &(&1 in supported)) do
      [] -> Enum.take(supported, 1)
      filtered -> filtered
    end
  end

  defp transform_model(model) do
    %{
      "id" => model["id"],
      "name" => model["name"],
      "reasoning" => model["reasoning"] || false,
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
end
