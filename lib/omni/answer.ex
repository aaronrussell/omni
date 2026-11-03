defmodule Omni.Answer do
  @moduledoc """
  Answers to the questions of a decision.

  `Omni.decide/3` returns a `%Omni.Decision{}` whose `:answers` is a keyword
  list aligned with its questions, one answer per question:

    * `Omni.Answer.Predicate` — answers an `Omni.Question.Predicate`
    * `Omni.Answer.Choice` — answers an `Omni.Question.Choice`
    * `Omni.Answer.Score` — answers an `Omni.Question.Score`
    * `Omni.Answer.Refusal` — the model declined the question

  Pattern match on the struct:

      case decision.answers[:team] do
        %Omni.Answer.Choice{choice: team} -> route(team)
        %Omni.Answer.Refusal{} -> route(:manual)
      end
  """

  alias Omni.Answer.{Choice, Predicate, Refusal, Score}

  @typedoc "An answer to a decision question."
  @type t :: Predicate.t() | Choice.t() | Score.t() | Refusal.t()
end
