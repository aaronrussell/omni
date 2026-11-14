defmodule Omni.Usage do
  @moduledoc """
  Token counts and computed costs for a request.

  Costs are computed from token counts and the pricing data on the `%Model{}`
  struct (see `price/2`). Available on every `%Response{}` via
  `response.usage`, and on every `%Decision{}` via `decision.usage`.

  ## Struct fields

  - `:input_tokens`, `:output_tokens` - request and generated token counts
  - `:cache_read_tokens`, `:cache_write_tokens` - prompt caching token counts
  - `:total_tokens` - sum of all token counts
  - `:input_cost`, `:output_cost`, `:cache_read_cost`, `:cache_write_cost` -
    per-category USD costs derived from model pricing
  - `:total_cost` - sum of all USD cost fields

  All fields default to `0`. Use `add/2` and `sum/1` to accumulate across
  multiple requests.
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

  @doc """
  Fills totals and costs from the token counts and a model's pricing.

  Each cost is the token count times the model's rate per million tokens; a
  missing rate (or a `nil` model) costs nothing. `:total_tokens` and
  `:total_cost` are the sums of the four categories. Existing costs and
  totals are overwritten.

  ```elixir
  usage = Usage.new(input_tokens: 1_000, output_tokens: 200)
  Usage.price(usage, model)
  #=> %Usage{input_tokens: 1000, output_tokens: 200, total_tokens: 1200,
  #          input_cost: 0.003, output_cost: 0.003, total_cost: 0.006, ...}
  ```
  """
  @spec price(t(), Omni.Model.t() | nil) :: t()
  def price(%__MODULE__{} = usage, model) do
    input_cost = cost(usage.input_tokens, model, :input_cost)
    output_cost = cost(usage.output_tokens, model, :output_cost)
    cache_read_cost = cost(usage.cache_read_tokens, model, :cache_read_cost)
    cache_write_cost = cost(usage.cache_write_tokens, model, :cache_write_cost)

    %{
      usage
      | total_tokens:
          usage.input_tokens + usage.output_tokens + usage.cache_read_tokens +
            usage.cache_write_tokens,
        input_cost: input_cost,
        output_cost: output_cost,
        cache_read_cost: cache_read_cost,
        cache_write_cost: cache_write_cost,
        total_cost: input_cost + output_cost + cache_read_cost + cache_write_cost
    }
  end

  defp cost(tokens, model, field) do
    rate = (model && Map.get(model, field)) || 0
    tokens * rate / 1_000_000
  end

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
