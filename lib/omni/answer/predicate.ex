defmodule Omni.Answer.Predicate do
  @moduledoc """
  The answer to an `Omni.Question.Predicate`: the probability, from 0 to 1,
  that the statement is true.

      %Omni.Answer.Predicate{probability: 0.91}
  """

  defstruct [:probability]

  @typedoc "The answer to a yes/no question."
  @type t :: %__MODULE__{probability: float()}
end
