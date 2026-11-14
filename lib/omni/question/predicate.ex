defmodule Omni.Question.Predicate do
  @moduledoc """
  A yes/no question: how likely is a statement about the state to be true.

  Answered by `Omni.Answer.Predicate`. Build one with `new/2`, or
  `Omni.predicate/2`.

  ## Struct fields

  - `:instructions` - the statement or question, as parts (see
    `Omni.Question`)
  - `:criteria` - optional descriptions of what counts as true and false,
    `[true: "...", false: "..."]` (either key may be left out). Sent to
    System One hosts; OpenAI has no field for them and drops them
  """

  alias Omni.Decision

  defstruct [:instructions, :criteria]

  @typedoc "A yes/no question."
  @type t :: %__MODULE__{
          instructions: Omni.Question.instructions(),
          criteria: [{boolean(), String.t()}] | nil
        }

  @doc """
  Creates a yes/no question from a keyword list or map of fields, or from
  instructions as a string.

  Instructions are built into parts (see `Omni.Question`). Other forms of
  instructions, such as a map or a list, go through `new/2`.

  ```elixir
  Omni.Question.Predicate.new("Is this spam?")
  Omni.Question.Predicate.new(instructions: "Is this spam?", criteria: [true: "Advertising"])
  ```
  """
  @spec new(String.t() | Enumerable.t()) :: t()
  def new(instructions) when is_binary(instructions), do: new(instructions, nil)

  def new(attrs) do
    question = struct!(__MODULE__, attrs)
    %{question | instructions: Decision.parts(question.instructions)}
  end

  @doc """
  Creates a yes/no question from instructions and optional criteria.

  `criteria`, when given, describes what counts as true and what as false.
  System One hosts use it; OpenAI has no field for it, so it is dropped there.

  ```elixir
  Omni.Question.Predicate.new("Is this spam?", nil)

  Omni.Question.Predicate.new("Is this spam?",
    true: "Unsolicited advertising",
    false: "A legitimate conversation"
  )
  ```
  """
  @spec new(Omni.Question.instructions_input(), [{boolean(), String.t()}] | nil) :: t()
  def new(instructions, criteria), do: new(instructions: instructions, criteria: criteria)
end
