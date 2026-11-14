defmodule Omni.Question.Choice do
  @moduledoc """
  A question with one answer from a fixed set of choices.

  Answered by `Omni.Answer.Choice`. Build one with `new/2`, or `Omni.choice/2`.

  ## Struct fields

  - `:instructions` - the question, as parts (see `Omni.Question`)
  - `:choices` - the options in order, as `{key, description}` pairs. Keys
    are atoms or strings and come back as given in the answer; a `nil`
    description means the model judges the option by its key alone
  """

  alias Omni.{Decision, Question}

  defstruct [:instructions, choices: []]

  @typedoc "A question with one answer from a set of choices."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          choices: [Omni.Question.option()]
        }

  @doc """
  Creates a choice question from a keyword list or map of fields.

  Instructions are built into parts (see `Omni.Question`) and choices into
  `{key, description}` pairs, as in `new/2`.

  ```elixir
  Omni.Question.Choice.new(instructions: "...", choices: [:a, :b])
  ```
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    question = struct!(__MODULE__, attrs)

    %{
      question
      | instructions: Decision.parts(question.instructions),
        choices: Question.options(question.choices)
    }
  end

  @doc """
  Creates a question with one answer from a set of choices.

  Each choice is a key, or a `{key, description}` pair; a choice without a
  description is judged by its key alone.

  ```elixir
  Omni.Question.Choice.new("Which team owns this?", [:billing, :infra, :other])

  Omni.Question.Choice.new("Which team owns this?",
    billing: "Payments and refunds",
    infra: "Outages",
    other: nil
  )
  ```
  """
  @spec new(Question.instructions_input(), [Question.key() | Question.option()]) :: t()
  def new(instructions, choices), do: new(instructions: instructions, choices: choices)
end
