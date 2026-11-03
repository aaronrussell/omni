defmodule Omni.Question.Score do
  @moduledoc """
  A question rating the state on an ordered scale of levels.

  Answered by `%Omni.Answer.Score{}`, whose score is the probability-weighted
  average of the level indices (the first level is 0). Build one with
  `Omni.Question.score/2`.

  ## Struct fields

    * `:instructions` — the question, as a string (or a map or list, sent as
      JSON)
    * `:levels` — the levels from lowest to highest, as `{key, description}`
      pairs. Keys are atoms or strings and come back as given in the answer;
      a `nil` description means the key itself describes the level
  """

  defstruct [:instructions, levels: []]

  @typedoc "A question rating the state on an ordered scale."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          levels: [Omni.Question.option()]
        }
end
