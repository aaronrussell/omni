defmodule Omni.Model do
  @moduledoc """
  A data struct describing a specific LLM.

  Models carry identity, capabilities, and pricing information. They are loaded
  from JSON data files at startup rather than defined as individual modules.
  The `:provider` and `:dialect` fields hold direct module references, making
  the struct self-contained for callback dispatch.
  """

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

  @doc "Creates a new model struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
