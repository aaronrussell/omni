defmodule Omni.Question.Score do
  @moduledoc """
  A question rating the state on an ordered scale of levels.

  Answered by `Omni.Answer.Score`, whose score is the probability-weighted
  average of the level indices (the first level is 0). Build one with
  `new/2`, or `Omni.score/2`.

  ## Struct fields

  - `:instructions` - the question, as parts (see `Omni.Question`)
  - `:levels` - the levels from lowest to highest, as `{key, description}`
    pairs. Keys are atoms or strings and come back as given in the answer;
    a `nil` description means the key itself describes the level
  """

  alias Omni.{Decision, Question}

  defstruct [:instructions, levels: []]

  @typedoc "A question rating the state on an ordered scale."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          levels: [Omni.Question.option()]
        }

  @doc """
  Creates a score question from a keyword list or map of fields.

  Instructions are built into parts (see `Omni.Question`) and levels into
  `{key, description}` pairs, as in `new/2`.

  ```elixir
  Omni.Question.Score.new(instructions: "...", levels: [:a, :b])
  ```
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    question = struct!(__MODULE__, attrs)

    %{
      question
      | instructions: Decision.parts(question.instructions),
        levels: Question.options(question.levels)
    }
  end

  @doc """
  Creates a question rating the state on an ordered scale.

  Levels run from lowest to highest. Each is a key, or a `{key, description}`
  pair; the answer's score is the probability-weighted average of the level
  indices, starting at 0.

  ```elixir
  Omni.Question.Score.new("How angry is the customer?", ["Calm", "Frustrated", "Very angry"])

  Omni.Question.Score.new("How urgent is this?",
    low: "Can wait",
    medium: "Needs attention this week",
    high: "Needs attention today"
  )
  ```
  """
  @spec new(Question.instructions_input(), [Question.key() | Question.option()]) :: t()
  def new(instructions, levels), do: new(instructions: instructions, levels: levels)
end
