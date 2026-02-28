defmodule Omni.Model do
  @moduledoc """
  A data struct describing a specific LLM.

  Models carry identity, capabilities, and pricing information. They are loaded
  from JSON data files at startup rather than defined as individual modules.
  The `:provider` and `:dialect` fields hold direct module references, making
  the struct self-contained for callback dispatch.
  """

  @supported_modalities %{
    input: [:text, :image, :pdf],
    output: [:text]
  }

  @enforce_keys [:id, :name, :provider, :dialect]
  defstruct [
    :id,
    :name,
    :provider,
    :dialect,
    context_size: 0,
    max_output_tokens: 0,
    reasoning: false,
    input_modalities: [:text],
    output_modalities: [:text],
    input_cost: 0,
    output_cost: 0,
    cache_read_cost: 0,
    cache_write_cost: 0
  ]

  @typedoc """
  A model reference as `{provider_id, model_id}`.

  The provider ID is an atom identifying a loaded provider (e.g. `:anthropic`,
  `:openai`, `:google`). The model ID is the provider's string identifier
  for the model (e.g. `"claude-sonnet-4-5-20250514"`).
  """
  @type ref :: {atom(), String.t()}

  @typedoc "An LLM model descriptor."
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          provider: module(),
          dialect: module(),
          context_size: non_neg_integer(),
          max_output_tokens: non_neg_integer(),
          reasoning: boolean(),
          input_modalities: [atom()],
          output_modalities: [atom()],
          input_cost: number(),
          output_cost: number(),
          cache_read_cost: number(),
          cache_write_cost: number()
        }

  @doc false
  @spec supported_modalities(:input | :output) :: [atom()]
  def supported_modalities(type) when type in [:input, :output] do
    Map.get(@supported_modalities, type)
  end

  @doc """
  Looks up a model by provider ID and model ID from `:persistent_term`.

  Returns `{:ok, model}` if found, or an error tuple identifying what's missing.
  """
  @spec get(atom(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(provider_id, model_id) do
    case :persistent_term.get({Omni, provider_id}, nil) do
      nil ->
        {:error, {:unknown_provider, provider_id}}

      models ->
        case Map.get(models, model_id) do
          nil -> {:error, {:unknown_model, provider_id, model_id}}
          model -> {:ok, model}
        end
    end
  end

  @doc "Returns all models for a provider, or an error if the provider is unknown."
  @spec list(atom()) :: {:ok, [t()]} | {:error, term()}
  def list(provider_id) do
    case :persistent_term.get({Omni, provider_id}, nil) do
      nil -> {:error, {:unknown_provider, provider_id}}
      models -> {:ok, Map.values(models)}
    end
  end

  @doc "Creates a new model struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    model = struct!(__MODULE__, attrs)

    %{
      model
      | input_modalities: filter_modalities(model.input_modalities, supported_modalities(:input)),
        output_modalities:
          filter_modalities(model.output_modalities, supported_modalities(:output))
    }
  end

  defp filter_modalities(modalities, supported) do
    case Enum.filter(modalities, &(&1 in supported)) do
      [] -> [:text]
      filtered -> filtered
    end
  end
end
