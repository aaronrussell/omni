defmodule Omni.Question.Predicate do
  @moduledoc """
  A yes/no question: how likely is a statement about the state to be true.

  Answered by `%Omni.Answer.Predicate{}`. Build one with
  `Omni.Question.predicate/2`.

  ## Struct fields

    * `:instructions` — the statement or question, as a string (or a map or
      list, sent as JSON)
    * `:criteria` — optional descriptions of what counts as true and false,
      `[true: "...", false: "..."]` (either key may be left out). Sent to
      System One hosts; OpenAI has no field for them and drops them
  """

  defstruct [:instructions, :criteria]

  @typedoc "A yes/no question."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          criteria: [{boolean(), String.t()}] | nil
        }
end
