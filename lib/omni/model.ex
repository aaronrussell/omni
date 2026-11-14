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

  - `:id` - the provider's string identifier (e.g. `"claude-sonnet-5-5"`)
  - `:name` - human-readable display name (e.g. `"Claude Sonnet 5.5"`)
  - `:provider` - the `%Omni.Provider{}` serving the model
  - `:dialects` - the dialect module per capability (`:text`, `:decision`),
    e.g. `%{text: Omni.Dialects.AnthropicMessages}`
  - `:context_size` - maximum input tokens the model accepts
  - `:max_output_tokens` - maximum tokens the model can generate
  - `:thinking` - what thinking the model supports: `false` (none), `true`
    (supported, with no detail), or a map of what it accepts (see below)
  - `:input_modalities` - supported input types (`:text`, `:image`, `:pdf`)
  - `:output_modalities` - supported output types (`:text`)
  - `:input_cost` - USD cost per million input tokens
  - `:output_cost` - USD cost per million output tokens
  - `:cache_read_cost` - USD cost per million cached input tokens (read)
  - `:cache_write_cost` - USD cost per million cached input tokens (write)
  - `:release_date` - date the model was released (from models.dev)

  ## Capabilities and modalities

  A **capability** is a kind of request the model serves: `:text`
  (`Omni.generate_text/3`, `Omni.stream_text/3`) or `:decision`
  (`Omni.decide/3`). The keys of `:dialects` are the model's capabilities,
  each naming the dialect that speaks it; most models serve one, and a few
  serve both (OpenAI's `gpt-6-luna`). Read them with `capabilities/1`,
  `capability?/2` and `dialect/2`:

  ```elixir
  {:ok, models} = Omni.list_models(:openrouter)
  Enum.filter(models, &Omni.Model.capability?(&1, :decision))
  ```

  A **modality** is a kind of content going in or out: `:text`, `:image`,
  `:pdf`. Text generation checks attachments against `:input_modalities`.
  A decision's answers are structured text, so decision models report
  `output_modalities: [:text]`.

  `:thinking` and tool use are text features. Every catalog text model
  supports tool use (sources leave out those that don't), and decision
  models have `thinking: false`.

  ## Thinking

  `:thinking` tells dialects how to translate the `:thinking` request option
  into something the model accepts. A map carries any of:

  - `:efforts` - the effort values the model takes, as wire strings
    (`["low", "medium", "high"]`). `"none"` means it can be switched off.
  - `:toggle` - `true` when thinking is switched on and off as a whole
  - `:budget` - `{min, max}` when the model takes a token budget; either
    bound may be `nil`

  For example:

  ```elixir
  %Omni.Model{thinking: %{efforts: ["none", "low", "medium", "high"]}}
  %Omni.Model{thinking: %{toggle: true, budget: {0, 24_576}}}
  ```

  Sources fill it from catalog data. `true` means the model reasons but
  nothing more is known; requests then fall back to each dialect's plain
  encoding.

  ## Looking up models

  Most users access models through the top-level API with a model reference
  — Omni resolves it automatically:

  ```elixir
  {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, "Hello!")
  {:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", "Hello!")
  ```

  To inspect a model's capabilities or browse what's available:

  ```elixir
  {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
  model.context_size  #=> 1000000

  {:ok, models} = Omni.list_models(:openai)
  Enum.map(models, & &1.id)
  ```

  ## Model references

  A reference names a model by provider id and model id, as a tuple or a
  string. Strings take a colon or a slash; the provider id ends at the first
  of either, so model ids keep any they hold:

  ```elixir
  {:openrouter, "typesafe/jev-1.14"}
  "openrouter:typesafe/jev-1.14"
  "openrouter/typesafe/jev-1.14"
  ```

  The provider may be spelled as its catalog key (`"fireworks-ai:…"` for
  `:fireworks_ai`). A bare model id is not a reference: the same id can be
  served by many providers.

  `to_ref/2` writes a model or tuple in any form, `parse_ref/1` reads a string
  back into a tuple, and interpolation gives the colon form:

  ```elixir
  Model.to_ref(model)          #=> {:anthropic, "claude-sonnet-5-5"}
  Model.to_ref(model, :slash)  #=> "anthropic/claude-sonnet-5-5"
  "\#{model}"                   #=> "anthropic:claude-sonnet-5-5"

  Model.parse_ref("anthropic:claude-sonnet-5-5")
  #=> {:ok, {:anthropic, "claude-sonnet-5-5"}}
  ```

  ## Custom models

  When a model isn't in the source's catalog (new releases, fine-tunes),
  add it under its provider in config. A new model names its dialect, since
  there is no catalog data to take it from:

  ```elixir
  config :omni, :providers,
    openai: [
      models: [
        [id: "ft:gpt-4o:acme::abc123", dialects: %{text: Omni.Dialects.OpenAIResponses}]
      ]
    ]
  ```

  A decision model names its decision dialect the same way:

  ```elixir
  config :omni, :providers,
    ollama: [models: [[id: "clef", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}]]]
  ```

  An entry whose id the catalog already has is merged over the catalog
  model instead, which corrects catalog data without restating it:

  ```elixir
  config :omni, :providers,
    openai: [models: [[id: "gpt-6", context_size: 1_000_000]]]
  ```

  Or create and register one at runtime:

  ```elixir
  model = Omni.Model.new(
    id: "my-fine-tune",
    name: "My Fine-Tune",
    provider: :openai,
    dialects: %{text: Omni.Dialects.OpenAIResponses},
    context_size: 128_000,
    max_output_tokens: 16_384,
    input_cost: 2.0,
    output_cost: 8.0
  )

  Omni.put_model(model)
  ```

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
    thinking: false,
    input_modalities: [:text],
    output_modalities: [:text],
    input_cost: 0,
    output_cost: 0,
    cache_read_cost: 0,
    cache_write_cost: 0
  ]

  @typedoc """
  A model reference: `{provider_id, model_id}`, `"provider_id:model_id"` or
  `"provider_id/model_id"`.

  The provider id is a loaded provider's atom id (e.g. `:anthropic`), or in a
  string that id or its catalog key (`"fireworks-ai"`). The model id is the
  provider's string identifier for the model (e.g. `"claude-sonnet-5-5"`). A
  string's provider id ends at its first `:` or `/`. See "Model references"
  in the moduledoc.
  """
  @type ref :: {atom(), String.t()} | String.t()

  @typedoc "A form `to_ref/2` writes a reference in."
  @type ref_format :: :tuple | :colon | :slash

  @typedoc "What thinking a model supports: none, unknown detail, or what it accepts."
  @type thinking ::
          boolean()
          | %{
              optional(:efforts) => [String.t()],
              optional(:toggle) => true,
              optional(:budget) => {non_neg_integer() | nil, non_neg_integer() | nil}
            }

  @typedoc "A capability a model can serve: text generation or decisions."
  @type capability :: :text | :decision

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
          dialects: %{optional(capability()) => module()},
          context_size: non_neg_integer(),
          max_output_tokens: non_neg_integer(),
          thinking: thinking(),
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
  Writes a model, or a `{provider_id, model_id}` tuple, as a reference.

  The format is `:tuple` (the default), `:colon` or `:slash`. To reformat a
  string reference, read it with `parse_ref/1` first.

  ```elixir
  {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
  Model.to_ref(model)          #=> {:anthropic, "claude-sonnet-5-5"}
  Model.to_ref(model, :colon)  #=> "anthropic:claude-sonnet-5-5"
  Model.to_ref(model, :slash)  #=> "anthropic/claude-sonnet-5-5"
  ```
  """
  @spec to_ref(t() | {atom(), String.t()}, ref_format()) :: ref()
  def to_ref(model, format \\ :tuple)

  def to_ref(%__MODULE__{provider: %Provider{id: provider_id}, id: model_id}, format),
    do: to_ref({provider_id, model_id}, format)

  def to_ref({provider_id, model_id} = ref, :tuple)
      when is_atom(provider_id) and is_binary(model_id),
      do: ref

  def to_ref({provider_id, model_id}, :colon) when is_atom(provider_id) and is_binary(model_id),
    do: "#{provider_id}:#{model_id}"

  def to_ref({provider_id, model_id}, :slash) when is_atom(provider_id) and is_binary(model_id),
    do: "#{provider_id}/#{model_id}"

  @doc """
  Reads a string reference into a `{provider_id, model_id}` tuple.

  The provider id is everything before the first `:` or `/`, and may be
  spelled as its catalog key. The provider must be loaded; the model is not
  looked up (see `get/1`).

  ```elixir
  Model.parse_ref("openrouter:typesafe/jev-1.14")  #=> {:ok, {:openrouter, "typesafe/jev-1.14"}}
  Model.parse_ref("fireworks-ai/accounts/fireworks/models/kimi-k3")
  #=> {:ok, {:fireworks_ai, "accounts/fireworks/models/kimi-k3"}}
  ```

  Returns `{:error, {:invalid_model_ref, ref}}` when the string has no
  provider and model id to split, and `{:error, {:unknown_provider, name}}`,
  with the provider as written, when that provider isn't loaded.
  """
  @spec parse_ref(String.t()) ::
          {:ok, {atom(), String.t()}}
          | {:error, {:invalid_model_ref, String.t()} | {:unknown_provider, String.t()}}
  def parse_ref(ref) when is_binary(ref) do
    case String.split(ref, [":", "/"], parts: 2) do
      [name, model_id] when name != "" and model_id != "" ->
        with {:ok, provider_id} <- loaded_provider(name), do: {:ok, {provider_id, model_id}}

      _ ->
        {:error, {:invalid_model_ref, ref}}
    end
  end

  # Matches a loaded provider without creating atoms from the input: an id
  # with no atom can't be loaded.
  defp loaded_provider(name) do
    id = name |> String.replace("-", "_") |> String.to_existing_atom()

    case Provider.get(id) do
      {:ok, _provider} -> {:ok, id}
      {:error, _} -> {:error, {:unknown_provider, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_provider, name}}
  end

  @doc """
  Returns the model's dialect for a capability.

  ```elixir
  {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
  Model.dialect(model, :text)      #=> {:ok, Omni.Dialects.AnthropicMessages}
  Model.dialect(model, :decision)  #=> {:error, {:unsupported_capability, :decision}}
  ```
  """
  @spec dialect(t(), capability()) ::
          {:ok, module()} | {:error, {:unsupported_capability, capability()}}
  def dialect(%__MODULE__{dialects: dialects}, capability) do
    case dialects do
      %{^capability => dialect} when is_atom(dialect) and not is_nil(dialect) -> {:ok, dialect}
      _ -> {:error, {:unsupported_capability, capability}}
    end
  end

  @doc """
  Returns the capabilities the model serves, in sorted order.

  ```elixir
  {:ok, model} = Omni.get_model(:openai, "gpt-6-luna")
  Model.capabilities(model)  #=> [:decision, :text]
  ```
  """
  @spec capabilities(t()) :: [capability()]
  def capabilities(%__MODULE__{dialects: dialects}),
    do: dialects |> Map.keys() |> Enum.sort()

  @doc """
  Returns whether the model serves a capability.

  ```elixir
  {:ok, models} = Omni.list_models(:openrouter)
  Enum.filter(models, &Model.capability?(&1, :decision))
  ```
  """
  @spec capability?(t(), capability()) :: boolean()
  def capability?(%__MODULE__{} = model, capability),
    do: match?({:ok, _}, dialect(model, capability))

  @doc """
  Looks up a model by reference: a tuple or a string (see `t:ref/0`).

  ```elixir
  Model.get("anthropic:claude-sonnet-5-5")
  Model.get({:anthropic, "claude-sonnet-5-5"})
  ```

  Returns the errors of `parse_ref/1` for a string, then those of `get/2`.
  """
  @spec get(ref()) :: {:ok, t()} | {:error, term()}
  def get(ref) when is_binary(ref) do
    with {:ok, {provider_id, model_id}} <- parse_ref(ref), do: get(provider_id, model_id)
  end

  def get({provider_id, model_id}), do: get(provider_id, model_id)

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
  provider must be loaded, and the model must name its dialects. See the
  "Custom models" section in the moduledoc for a full example.
  """
  @spec put(t()) :: :ok
  def put(%__MODULE__{provider: %Provider{}} = model), do: Omni.Provider.Loader.put_model(model)

  def put(%__MODULE__{} = model) do
    raise ArgumentError, "cannot register model #{inspect(model.id)}: it has no provider"
  end

  @doc """
  Creates a new model struct from a keyword list or map.

  `:provider` may be a `%Omni.Provider{}` or the id of a loaded provider.
  `:dialects` maps each capability to its dialect (`%{text: Module}`); it is
  never filled from the provider, so a model without one can't make
  requests. `:thinking` takes a
  boolean or a map (or keyword list) of `:efforts`, `:toggle` and `:budget`;
  an empty map means `true`.

  Normalizes modalities to the supported set — unsupported values are silently
  dropped, and an empty list defaults to `[:text]`. Does not validate field
  values; validation happens at the API boundary. See the "Custom models"
  section in the moduledoc for a full example.
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)

    if Map.has_key?(attrs, :reasoning) do
      raise ArgumentError,
            "the model :reasoning attribute was renamed to :thinking — use thinking: true, " <>
              "or a map such as thinking: %{efforts: [\"low\", \"high\"]}"
    end

    provider = resolve_provider(Map.get(attrs, :provider))

    dialects = attrs |> Map.get(:dialects, %{}) |> Map.new()

    model =
      struct!(
        __MODULE__,
        Map.merge(attrs, %{
          provider: provider,
          dialects: dialects,
          thinking: normalize_thinking(Map.get(attrs, :thinking, false))
        })
      )

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

  defp normalize_thinking(thinking) when is_boolean(thinking), do: thinking
  defp normalize_thinking(nil), do: false

  defp normalize_thinking(thinking) when is_map(thinking) or is_list(thinking) do
    thinking
    |> Map.new()
    |> Enum.reduce(%{}, fn
      {:efforts, [_ | _] = efforts}, acc ->
        Map.put(acc, :efforts, Enum.map(efforts, &to_string/1))

      {:toggle, true}, acc ->
        Map.put(acc, :toggle, true)

      {:budget, {min, max}}, acc ->
        Map.put(acc, :budget, {min, max})

      _, acc ->
        acc
    end)
    |> case do
      empty when map_size(empty) == 0 -> true
      thinking -> thinking
    end
  end

  defp filter_modalities(modalities, supported) do
    case Enum.filter(modalities, &(&1 in supported)) do
      [] -> [:text]
      filtered -> filtered
    end
  end
end

defimpl String.Chars, for: Omni.Model do
  def to_string(model), do: Omni.Model.to_ref(model, :colon)
end
