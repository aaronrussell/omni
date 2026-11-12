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

  Build them with `Omni.predicate/2`, `Omni.choice/2` and `Omni.score/2`,
  which delegate to each struct's `new/2`:

      [
        urgent: Omni.predicate("Does this need a reply within the hour?"),
        team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
        anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
      ]

  Choices and levels take a list of keys, or of `key: description` pairs, or
  a mix of both. Keys may be atoms or strings, and the answer uses them as
  given. Questions are validated when the decision is sent, not here.

  ## Instructions

  Instructions are parts, like the state (see `Omni.Decision`): a string is
  one text part, a map one data part sent as JSON, and a list gives a part
  for each item. The constructors build them, so the struct holds
  `[%Omni.Content.Text{}]` for a string.

      Omni.predicate(%{question: "Does the ticket report an outage?", field: "ticket.body"})
  """

  alias Omni.Decision
  alias Omni.Question.{Choice, Predicate, Score}

  @typedoc "A decision question."
  @type t :: Predicate.t() | Choice.t() | Score.t()

  @typedoc "Question instructions, as parts (see [Instructions](#module-instructions))."
  @type instructions :: [Decision.part()]

  @typedoc "Instructions as given to a constructor: a string, a map, a part, or a list of them."
  @type instructions_input ::
          String.t() | map() | Decision.part() | [String.t() | map() | Decision.part()]

  @typedoc "A choice or level key, as given by the caller."
  @type key :: atom() | String.t()

  @typedoc "A choice or level: its key and an optional description."
  @type option :: {key(), String.t() | nil}

  @doc false
  # Normalises choices or levels: a bare key becomes {key, nil}; pairs are
  # kept. Anything else is left for validation to reject. Safe to repeat.
  @spec options(term()) :: term()
  def options(list) when is_list(list) do
    Enum.map(list, fn
      {_key, _description} = pair -> pair
      key when is_atom(key) or is_binary(key) -> {key, nil}
      other -> other
    end)
  end

  def options(other), do: other
end
