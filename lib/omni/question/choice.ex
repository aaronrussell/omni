defmodule Omni.Question.Choice do
  @moduledoc """
  A question with one answer from a fixed set of choices.

  Answered by `%Omni.Answer.Choice{}`. Build one with `Omni.Question.choice/2`.

  ## Struct fields

    * `:instructions` — the question, as parts (see `Omni.Question`)
    * `:choices` — the options in order, as `{key, description}` pairs. Keys
      are atoms or strings and come back as given in the answer; a `nil`
      description means the model judges the option by its key alone
  """

  defstruct [:instructions, choices: []]

  @typedoc "A question with one answer from a set of choices."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          choices: [Omni.Question.option()]
        }
end
