defmodule Omni.Model do
  @moduledoc """
  A data struct describing a specific LLM.

  Models carry identity, capabilities, and pricing information. They are loaded
  from JSON data files in `priv/models/` at startup rather than defined as
  individual modules. The `:provider` and `:dialect` fields hold direct module
  references, making the struct self-contained for callback dispatch — given a
  `%Model{}`, Omni knows where to send the request and how to format it.

  ## Struct fields

    * `:id` — the provider's string identifier (e.g. `"claude-sonnet-4-5-20250514"`)
    * `:name` — human-readable display name (e.g. `"Claude Sonnet 4.5"`)
    * `:provider` — the provider module (e.g. `Omni.Providers.Anthropic`)
    * `:dialect` — the dialect module (e.g. `Omni.Dialects.AnthropicMessages`)
    * `:context_size` — maximum input tokens the model accepts
    * `:max_output_tokens` — maximum tokens the model can generate
    * `:reasoning` — whether the model supports extended thinking
    * `:input_modalities` — supported input types (`:text`, `:image`, `:pdf`)
    * `:output_modalities` — supported output types (`:text`)
    * `:input_cost` — cost per million input tokens
    * `:output_cost` — cost per million output tokens
    * `:cache_read_cost` — cost per million cached input tokens (read)
    * `:cache_write_cost` — cost per million cached input tokens (write)

  ## Looking up models

  Most users access models through the top-level API with `{provider_id,
  model_id}` tuples — Omni resolves them automatically:

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

  To inspect a model's capabilities or browse what's available:

      {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-4-5-20250514")
      model.context_size  #=> 200000

      {:ok, models} = Omni.list_models(:openai)
      Enum.map(models, & &1.id)

  ## Custom models

  When a model isn't in the built-in JSON data (new releases, fine-tunes,
  self-hosted endpoints), create and register it manually:

      model = Omni.Model.new(
        id: "my-fine-tune",
        name: "My Fine-Tune",
        provider: Omni.Providers.OpenAI,
        dialect: Omni.Dialects.OpenAICompletions,
        context_size: 128_000,
        max_output_tokens: 16_384,
        input_cost: 2.0,
        output_cost: 8.0
      )

      Omni.put_model(:openai, model)

  The model is now discoverable via `Omni.get_model/2` and `Omni.list_models/1`,
  and can be used directly as a struct with `generate_text/3` and `stream_text/3`.
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

  @typedoc """
  An LLM model descriptor.

  The `:provider` and `:dialect` fields are module references used for callback
  dispatch. Cost fields are per million tokens. Modalities are filtered to the
  supported set (see `new/1`).
  """
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

  @doc """
  Registers a model in `:persistent_term` under the given provider ID.

  Use this to make a hand-built model discoverable via `get/2` and `list/1`.
  If a model with the same ID already exists for that provider, it is replaced.

      model = Model.new(
        id: "my-custom-model",
        name: "My Custom Model",
        provider: Omni.Providers.OpenAI,
        dialect: Omni.Dialects.OpenAICompletions,
        context_size: 128_000,
        max_output_tokens: 16_384,
        input_cost: 2.0,
        output_cost: 8.0
      )

      Model.put(:openai, model)
  """
  @spec put(atom(), t()) :: :ok
  def put(provider_id, %__MODULE__{} = model) do
    existing = :persistent_term.get({Omni, provider_id}, %{})
    :persistent_term.put({Omni, provider_id}, Map.put(existing, model.id, model))
    :ok
  end

  @doc """
  Creates a new model struct from a keyword list or map.

  Normalizes modalities to the supported set — unsupported values are silently
  dropped, and an empty list defaults to `[:text]`. Does not validate field
  values; validation happens at the API boundary.

      model = Model.new(
        id: "my-model",
        name: "My Model",
        provider: Omni.Providers.OpenAI,
        dialect: Omni.Dialects.OpenAICompletions,
        context_size: 128_000,
        max_output_tokens: 16_384,
        input_cost: 2.0,
        output_cost: 8.0
      )
  """
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
