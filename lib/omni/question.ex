defmodule Omni.Question do
  @moduledoc """
  Typed questions for `Omni.decide/3`.

  A decision asks one or more questions about a shared state. Each question
  is a struct, and its type decides the shape of its answer:

    * `Omni.Question.Predicate` — yes or no, answered with a probability
    * `Omni.Question.Choice` — one of a set of choices, answered with a
      probability for each
    * `Omni.Question.Score` — a rating on an ordered scale, answered with a
      probability for each level and their weighted average

  Build them with the constructors here, also available as
  `Omni.predicate/2`, `Omni.choice/2` and `Omni.score/2`:

      [
        urgent: Omni.predicate("Does this need a reply within the hour?"),
        team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
        anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
      ]

  Choices and levels take a list of keys, or of `key: description` pairs, or
  a mix of both. Keys may be atoms or strings, and the answer uses them as
  given. Questions are validated when the decision is sent, not here.
  """

  alias Omni.Question.{Choice, Predicate, Score}

  @typedoc "A decision question."
  @type t :: Predicate.t() | Choice.t() | Score.t()

  @typedoc "Question instructions: a string, or a map or list sent as JSON."
  @type instructions :: String.t() | map() | list()

  @typedoc "A choice or level key, as given by the caller."
  @type key :: atom() | String.t()

  @typedoc "A choice or level: its key and an optional description."
  @type option :: {key(), String.t() | nil}

  @doc """
  Creates a yes/no question.

  `criteria`, when given, describes what counts as true and what as false.
  System One hosts use it; OpenAI has no field for it, so it is dropped there.

      Omni.Question.predicate("Is this spam?")

      Omni.Question.predicate("Is this spam?",
        true: "Unsolicited advertising",
        false: "A legitimate conversation"
      )
  """
  @spec predicate(instructions(), [{boolean(), String.t()}] | nil) :: Predicate.t()
  def predicate(instructions, criteria \\ nil) do
    %Predicate{instructions: instructions, criteria: criteria}
  end

  @doc """
  Creates a question with one answer from a set of choices.

  Each choice is a key, or a `{key, description}` pair; a choice without a
  description is judged by its key alone.

      Omni.Question.choice("Which team owns this?", [:billing, :infra, :other])

      Omni.Question.choice("Which team owns this?",
        billing: "Payments and refunds",
        infra: "Outages",
        other: nil
      )
  """
  @spec choice(instructions(), [key() | option()]) :: Choice.t()
  def choice(instructions, choices) do
    %Choice{instructions: instructions, choices: options(choices)}
  end

  @doc """
  Creates a question rating the state on an ordered scale.

  Levels run from lowest to highest. Each is a key, or a `{key, description}`
  pair; the answer's score is the probability-weighted average of the level
  indices, starting at 0.

      Omni.Question.score("How angry is the customer?", ["Calm", "Frustrated", "Very angry"])

      Omni.Question.score("How urgent is this?",
        low: "Can wait",
        medium: "Needs attention this week",
        high: "Needs attention today"
      )
  """
  @spec score(instructions(), [key() | option()]) :: Score.t()
  def score(instructions, levels) do
    %Score{instructions: instructions, levels: options(levels)}
  end

  # A bare key becomes {key, nil}; pairs are kept. Anything else is left for
  # validation to reject.
  defp options(list) when is_list(list) do
    Enum.map(list, fn
      {_key, _description} = pair -> pair
      key when is_atom(key) or is_binary(key) -> {key, nil}
      other -> other
    end)
  end

  defp options(other), do: other
end
