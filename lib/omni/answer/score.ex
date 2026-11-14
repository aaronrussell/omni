defmodule Omni.Answer.Score do
  @moduledoc """
  The answer to an `Omni.Question.Score`.

  ```elixir
  %Omni.Answer.Score{
    score: 1.4,
    probabilities: [{"Calm", 0.1}, {"Frustrated but civil", 0.4}, {"Very angry", 0.5}],
    confidence: 0.4
  }
  ```

  ## Struct fields

  - `:score` - the probability-weighted average of the level indices, the
    first level being 0. It can fall between levels
  - `:probabilities` - `{key, probability}` for every level, in the
    question's order and with its keys
  - `:confidence` - the provider's confidence, or `nil` when it gives none.
    Hosts compute it differently, so compare it only within one provider;
    the probabilities are the portable result
  """

  defstruct [:score, :confidence, probabilities: []]

  @typedoc "The answer to a score question."
  @type t :: %__MODULE__{
          score: number(),
          probabilities: [{Omni.Question.key(), float()}],
          confidence: float() | nil
        }

  @doc "Creates a score answer from a keyword list or map of fields."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
