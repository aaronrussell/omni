defmodule Omni.Sources.ModelsDev do
  @moduledoc """
  The default model source, reading a bundled models.dev snapshot.

  The snapshot (`priv/models/models_dev.json`) is a verbatim capture of the
  full [models.dev](https://models.dev) catalog, refreshed with
  `mix omni.snapshot`. It is transformed into `%Omni.Model{}` structs at load
  time: deprecated models and those without tool use or text modalities are
  filtered out, modalities are narrowed to those Omni supports, and each
  model's dialect is inferred from models.dev's npm package metadata, falling
  back to the provider's declared dialect. Models that still fail to build
  are skipped with a warning.

  Built-in providers are matched to their catalog entries automatically.
  Custom providers pass `provider_id:` — any models.dev catalog id works,
  including providers Omni ships no module for:

      defmodule MyApp.Providers.Mistral do
        use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

        @impl true
        def config do
          %{base_url: "https://api.mistral.ai", api_key: {:system, "MISTRAL_API_KEY"}}
        end

        @impl true
        def models, do: Omni.Provider.load_models(__MODULE__, provider_id: :mistral)
      end

  A live mode (fetching fresh catalog data from models.dev at boot, with a
  local cache) is planned; until then the source accepts no options besides
  `:provider_id`.
  """

  @behaviour Omni.Source

  require Logger

  alias Omni.{Model, Provider}

  @catalog_key {__MODULE__, :catalog}
  @snapshot_file "priv/models/models_dev.json"

  # Omni provider id -> models.dev catalog key
  @renames %{moonshot: "moonshotai", ollama: "ollama-cloud"}

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

  @supported_input_modalities Enum.map(Model.supported_modalities(:input), &to_string/1)
  @supported_output_modalities Enum.map(Model.supported_modalities(:output), &to_string/1)

  @impl Omni.Source
  def fetch(module, opts) do
    with {:ok, catalog_id} <- resolve_catalog_id(module, opts),
         {:ok, provider_data} <- lookup(catalog_id) do
      {:ok, transform_provider(provider_data, module, catalog_id)}
    end
  end

  defp resolve_catalog_id(module, opts) do
    case Keyword.fetch(opts, :provider_id) do
      {:ok, id} ->
        {:ok, to_string(id)}

      :error ->
        case Enum.find(Provider.builtin_providers(), fn {_id, mod} -> mod == module end) do
          {omni_id, _mod} -> {:ok, @renames[omni_id] || to_string(omni_id)}
          nil -> {:error, :unknown_provider}
        end
    end
  end

  defp lookup(catalog_id) do
    case Map.fetch(catalog(), catalog_id) do
      {:ok, provider_data} -> {:ok, provider_data}
      :error -> {:error, :unknown_provider}
    end
  end

  # The decoded snapshot (~9 MB of terms) is memoized for the duration of a
  # load pass — fetch/2 runs once per provider — and garbage collected when
  # the pass ends, instead of lingering for the VM's lifetime.
  defp catalog do
    Omni.Source.memo(@catalog_key, fn ->
      :omni
      |> Application.app_dir(@snapshot_file)
      |> File.read!()
      |> JSON.decode!()
    end)
  end

  @doc false
  @spec transform_provider(map(), module(), String.t()) :: [Model.t()]
  def transform_provider(provider_data, module, catalog_id) do
    {models, skipped} =
      provider_data
      |> get_models()
      |> Enum.filter(&eligible?/1)
      |> Enum.reduce({[], 0}, fn model_data, {models, skipped} ->
        case build(model_data, module, provider_data, catalog_id) do
          {:ok, model} -> {[model | models], skipped}
          :skip -> {models, skipped + 1}
        end
      end)

    if skipped > 0 do
      Logger.warning(
        "Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models, " <>
          "skipped #{skipped}"
      )
    else
      Logger.debug("Omni.Sources.ModelsDev: #{catalog_id}: loaded #{length(models)} models")
    end

    Enum.sort_by(models, & &1.id)
  end

  defp get_models(%{"models" => models}) when is_map(models), do: Map.values(models)
  defp get_models(%{"models" => models}) when is_list(models), do: models
  defp get_models(_), do: []

  defp eligible?(model) when is_map(model) do
    model["status"] != "deprecated" and model["tool_call"] == true and
      "text" in modality_list(model, "input") and "text" in modality_list(model, "output")
  end

  defp eligible?(_), do: false

  defp modality_list(model, key) do
    case model["modalities"] do
      %{^key => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp build(model_data, module, provider_data, catalog_id) do
    cost = model_data["cost"] || %{}
    limit = model_data["limit"] || %{}
    npm = get_in(model_data, ["provider", "npm"]) || provider_data["npm"]

    data = %{
      "id" => model_data["id"],
      "name" => model_data["name"],
      "reasoning" => model_data["reasoning"] || false,
      "release_date" => model_data["release_date"],
      "dialect" => @npm_to_dialect[npm],
      "input_modalities" =>
        filter_modalities(modality_list(model_data, "input"), @supported_input_modalities),
      "output_modalities" =>
        filter_modalities(modality_list(model_data, "output"), @supported_output_modalities),
      "input_cost" => cost["input"] || 0,
      "output_cost" => cost["output"] || 0,
      "cache_read_cost" => cost["cache_read"] || 0,
      "cache_write_cost" => cost["cache_write"] || 0,
      "context_size" => limit["context"] || 0,
      "max_output_tokens" => limit["output"] || 0
    }

    {:ok, Provider.build_model(module, data)}
  rescue
    e ->
      Logger.warning(
        "Omni.Sources.ModelsDev: skipping #{catalog_id}:#{model_data["id"]}: " <>
          Exception.message(e)
      )

      :skip
  end

  # Filters modality strings before Provider.build_model/2 atomizes them —
  # the unpruned snapshot carries modalities Omni has no atoms for.
  defp filter_modalities(modalities, supported) do
    Enum.filter(modalities, &(&1 in supported))
  end
end
