defmodule Omni.Model do
  @moduledoc """
  A data struct describing a specific LLM.

  Models carry identity, capabilities, and pricing information. They are loaded
  from the configured model source (see `Omni.Source`) when their provider
  loads, rather than defined as individual modules. Each model embeds its
  `%Omni.Provider{}` and names its dialect per capability, making the struct
  self-contained — given a `%Model{}`, Omni knows where to send the request
  and how to format it.

  ## Struct fields

    * `:id` — the provider's string identifier (e.g. `"claude-sonnet-4-5-20250514"`)
    * `:name` — human-readable display name (e.g. `"Claude Sonnet 4.5"`)
    * `:provider` — the `%Omni.Provider{}` serving the model
    * `:dialects` — the dialect module per capability, e.g.
      `%{text: Omni.Dialects.AnthropicMessages}`
    * `:context_size` — maximum input tokens the model accepts
    * `:max_output_tokens` — maximum tokens the model can generate
    * `:reasoning` — whether the model supports extended thinking
    * `:input_modalities` — supported input types (`:text`, `:image`, `:pdf`)
    * `:output_modalities` — supported output types (`:text`)
    * `:input_cost` — USD cost per million input tokens
    * `:output_cost` — USD cost per million output tokens
    * `:cache_read_cost` — USD cost per million cached input tokens (read)
    * `:cache_write_cost` — USD cost per million cached input tokens (write)
    * `:release_date` — date the model was released (from models.dev)

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

  When a model isn't in the source's catalog (new releases, fine-tunes),
  add it under its provider in config:

      config :omni, :providers,
        openai: [models: [[id: "ft:gpt-4o:acme::abc123", context_size: 128_000]]]

  Or create and register one at runtime:

      model = Omni.Model.new(
        id: "my-fine-tune",
        name: "My Fine-Tune",
        provider: :openai,
        context_size: 128_000,
        max_output_tokens: 16_384,
        input_cost: 2.0,
        output_cost: 8.0
      )

      Omni.put_model(model)

  The model is now discoverable via `Omni.get_model/2` and `Omni.list_models/1`,
  and can be used directly as a struct with `generate_text/3` and `stream_text/3`.
  """

  alias Omni.Provider

  @supported_modalities %{
    input: [:text, :image, :pdf],
    output: [:text]
  }

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :provider,
    :release_date,
    dialects: %{},
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

  `:provider` is the embedded provider struct and `:dialects` the dialect
  module per capability. Cost fields are per million tokens. Modalities are
  filtered to the supported set (see `new/1`).
  """
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          provider: Provider.t() | nil,
          dialects: %{optional(atom()) => module()},
          context_size: non_neg_integer(),
          max_output_tokens: non_neg_integer(),
          reasoning: boolean(),
          input_modalities: [atom()],
          output_modalities: [atom()],
          input_cost: number(),
          output_cost: number(),
          cache_read_cost: number(),
          cache_write_cost: number(),
          release_date: Date.t() | nil
        }

  @doc false
  @spec supported_modalities(:input | :output) :: [atom()]
  def supported_modalities(type) when type in [:input, :output] do
    Map.get(@supported_modalities, type)
  end

  @doc """
  Converts a model back to its `{provider_id, model_id}` lookup reference.

      {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-4-5-20250514")
      Model.to_ref(model)
      #=> {:anthropic, "claude-sonnet-4-5-20250514"}
  """
  @spec to_ref(t()) :: ref()
  def to_ref(%__MODULE__{provider: %Provider{id: provider_id}} = model) do
    {provider_id, model.id}
  end

  @doc """
  Looks up a model by provider ID and model ID.

  Returns `{:ok, model}` if found, or an error tuple identifying what's
  missing. `{:unknown_provider, id}` means the provider isn't loaded — it
  doesn't exist, or isn't selected in `config :omni, :models, providers:`.
  """
  @spec get(atom(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(provider_id, model_id) do
    with {:ok, models} <- models(provider_id) do
      case Map.get(models, model_id) do
        nil -> {:error, {:unknown_model, provider_id, model_id}}
        model -> {:ok, model}
      end
    end
  end

  @doc "Returns all models for a provider, or an error if the provider isn't loaded."
  @spec list(atom()) :: {:ok, [t()]} | {:error, term()}
  def list(provider_id) do
    with {:ok, models} <- models(provider_id), do: {:ok, Map.values(models)}
  end

  defp models(provider_id) do
    with {:ok, _provider} <- Provider.get(provider_id) do
      {:ok, :persistent_term.get(Provider.models_key(provider_id), %{})}
    end
  end

  @doc """
  Registers a model under its provider.

  Makes the model discoverable via `get/2` and `list/1`. If a model with the
  same ID already exists for that provider, it is replaced. The model's
  provider must be loaded. See the "Custom models" section in the moduledoc
  for a full example.
  """
  @spec put(t()) :: :ok
  def put(%__MODULE__{provider: %Provider{}} = model), do: Omni.Provider.Loader.put_model(model)

  def put(%__MODULE__{} = model) do
    raise ArgumentError, "cannot register model #{inspect(model.id)}: it has no provider"
  end

  @doc """
  Creates a new model struct from a keyword list or map.

  `:provider` may be a `%Omni.Provider{}` or the id of a loaded provider.
  `:dialects` is optional: `%{text: Module}`, with any capability missing
  filled from the provider's first dialect for it.

  Normalizes modalities to the supported set — unsupported values are silently
  dropped, and an empty list defaults to `[:text]`. Does not validate field
  values; validation happens at the API boundary. See the "Custom models"
  section in the moduledoc for a full example.
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    provider = resolve_provider(Map.get(attrs, :provider))

    dialects =
      attrs
      |> Map.get(:dialects, %{})
      |> Map.new()
      |> fill_dialects(provider)

    model = struct!(__MODULE__, Map.merge(attrs, %{provider: provider, dialects: dialects}))

    %{
      model
      | input_modalities: filter_modalities(model.input_modalities, supported_modalities(:input)),
        output_modalities:
          filter_modalities(model.output_modalities, supported_modalities(:output))
    }
  end

  defp resolve_provider(nil), do: nil
  defp resolve_provider(%Provider{} = provider), do: provider

  defp resolve_provider(id) when is_atom(id) do
    case Provider.get(id) do
      {:ok, provider} ->
        provider

      {:error, _} ->
        raise ArgumentError, "cannot build model: provider #{inspect(id)} is not loaded"
    end
  end

  defp fill_dialects(dialects, nil), do: dialects

  defp fill_dialects(dialects, %Provider{dialects: defaults}) do
    Enum.reduce(defaults, dialects, fn
      {capability, [first | _]}, acc -> Map.put_new(acc, capability, first)
      _, acc -> acc
    end)
  end

  defp filter_modalities(modalities, supported) do
    case Enum.filter(modalities, &(&1 in supported)) do
      [] -> [:text]
      filtered -> filtered
    end
  end
end
