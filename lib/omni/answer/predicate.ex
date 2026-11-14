defmodule Omni.Answer.Predicate do
  @moduledoc """
  The answer to an `Omni.Question.Predicate`.

  ```elixir
  %Omni.Answer.Predicate{probability: 0.91}
  ```

  ## Struct fields

  - `:probability` - the probability, from 0 to 1, that the statement is
    true
  """

  defstruct [:probability]

  @typedoc "The answer to a yes/no question."
  @type t :: %__MODULE__{probability: float()}

  @doc "Creates a predicate answer from a keyword list or map of fields."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
