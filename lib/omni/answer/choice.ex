defmodule Omni.Answer.Choice do
  @moduledoc """
  The answer to an `Omni.Question.Choice`.

      %Omni.Answer.Choice{
        choice: :infra,
        probabilities: [billing: 0.02, infra: 0.95, other: 0.03],
        confidence: 0.93
      }

  ## Struct fields

    * `:choice` — the most likely choice, by the question's key
    * `:probabilities` — `{key, probability}` for every choice, in the
      question's order and with its keys
    * `:confidence` — the provider's confidence in the choice, or `nil` when
      it gives none. Hosts compute it differently, so compare it only within
      one provider; the probabilities are the portable result
  """

  defstruct [:choice, :confidence, probabilities: []]

  @typedoc "The answer to a choice question."
  @type t :: %__MODULE__{
          choice: Omni.Question.key(),
          probabilities: [{Omni.Question.key(), float()}],
          confidence: float() | nil
        }

  @doc "Creates a choice answer from a keyword list or map of fields."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
