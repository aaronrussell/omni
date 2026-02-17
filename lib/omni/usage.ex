defmodule Omni.Usage do
  @moduledoc """
  Token counts and computed costs for a generation request.

  Costs are derived by multiplying token counts against the pricing data on the
  `%Model{}` struct. Use `add/2` and `sum/1` for accumulation across multiple
  requests.
  """

  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            total_tokens: 0,
            input_cost: 0,
            output_cost: 0,
            cache_read_cost: 0,
            cache_write_cost: 0,
            total_cost: 0

  @typedoc "Token usage and cost breakdown."
  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_cost: number(),
          output_cost: number(),
          cache_read_cost: number(),
          cache_write_cost: number(),
          total_cost: number()
        }

  @doc "Creates a new usage struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Sums corresponding fields of two usage structs."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    fields = Map.from_struct(a)
    merged = Map.merge(fields, Map.from_struct(b), fn _k, v1, v2 -> v1 + v2 end)
    struct!(__MODULE__, merged)
  end

  @doc "Reduces a list of usage structs into a single summed usage."
  @spec sum([t()]) :: t()
  def sum(usages) when is_list(usages), do: Enum.reduce(usages, %__MODULE__{}, &add/2)
end
