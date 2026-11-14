defmodule Omni.Dialects.TypeSafeSystemOne do
  @moduledoc """
  Dialect implementation for the System One decision format.

  System One is TypeSafe's decision API and the de facto open standard,
  served by TypeSafe, OpenRouter, OpenCode Zen, Ollama and others at
  `<base_url>/systemone`. See `Omni.Dialect.Decision` for the behaviour.

  ## Encoding

  - The state and each question's instructions are parts: one part is sent
    on its own (a text part as a string, a data part as an object), several
    as an array of them.
  - Questions go in a map keyed by name. A predicate is a `noul` question,
    and its criteria become `{"true": ..., "false": ...}`.
  - Choices are sent as `{key: description}`, a `nil` description meaning
    the choice is judged by its key.
  - Levels are sent as a list of descriptions, lowest first; a level with no
    description sends its key. System One numbers levels by position, so
    the keys only map the answer back.

  ## Answers

  Probabilities come back keyed by choice name or level index and are
  mapped to the question's keys, in the question's order. The level
  `legend` is dropped as redundant. A refused question (`{"type": "refusal"}`,
  which OpenRouter documents) is answered with an `Omni.Answer.Refusal`; the
  others are still answered.

  ## Compat flags

  None yet. Hosts differ in option caps (26 choices on some), whether
  `instructions` is required, and confidence formulas; Omni leaves caps to
  the provider and passes confidence through.
  """

  use Omni.Dialect, :decision

  alias Omni.{Answer, Decision, Model, Usage}
  alias Omni.Content.{Data, Text}
  alias Omni.Dialect
  alias Omni.Question.{Choice, Predicate, Score}

  @impl true
  def option_schema, do: %{}

  @impl true
  def compat_schema, do: %{}

  @impl true
  def auth, do: :bearer

  @impl true
  def handle_path(%Model{}, _opts), do: "/systemone"

  @impl true
  def handle_body(%Model{} = model, %Decision{} = decision, _opts) do
    %{
      "model" => model.id,
      "state" => encode_parts(decision.state),
      "questions" =>
        Map.new(decision.questions, fn {name, question} ->
          {Atom.to_string(name), encode_question(question)}
        end)
    }
  end

  @impl true
  def handle_response(%{"answers" => answers} = body, %Decision{} = decision, %Model{})
      when is_map(answers) do
    with {:ok, answers} <-
           Dialect.Decision.decode_answers(decision.questions, answers, &decode_answer/2) do
      {:ok, %{decision | answers: answers, usage: decode_usage(body["usage"])}}
    end
  end

  def handle_response(body, %Decision{}, %Model{}), do: {:error, {:invalid_response, body}}

  # -- Encoding --

  defp encode_parts([part]), do: encode_part(part)
  defp encode_parts(parts), do: Enum.map(parts, &encode_part/1)

  defp encode_part(%Text{text: text}), do: text
  defp encode_part(%Data{data: data}), do: data

  defp encode_question(%Predicate{} = question) do
    %{"type" => "noul", "instructions" => encode_parts(question.instructions)}
    |> put_criteria(question.criteria)
  end

  defp encode_question(%Choice{} = question) do
    %{
      "type" => "choice",
      "instructions" => encode_parts(question.instructions),
      "criteria" => Map.new(question.choices, fn {key, desc} -> {to_string(key), desc} end)
    }
  end

  defp encode_question(%Score{} = question) do
    %{
      "type" => "score",
      "instructions" => encode_parts(question.instructions),
      "criteria" => Enum.map(question.levels, fn {key, desc} -> desc || to_string(key) end)
    }
  end

  defp put_criteria(question, nil), do: question

  defp put_criteria(question, criteria) do
    Map.put(question, "criteria", Map.new(criteria, fn {key, text} -> {to_string(key), text} end))
  end

  # -- Decoding --

  defp decode_answer(%Predicate{}, %{"type" => "noul", "noul" => probability})
       when is_number(probability),
       do: {:ok, Answer.Predicate.new(probability: float(probability))}

  defp decode_answer(%Choice{choices: choices}, %{"type" => "choice"} = answer) do
    with {:ok, choice} <- Dialect.Decision.choice_key(choices, answer["choice"]),
         {:ok, probabilities} <-
           Dialect.Decision.probabilities(choices, answer["probabilities"], :key) do
      {:ok,
       Answer.Choice.new(
         choice: choice,
         probabilities: probabilities,
         confidence: float(answer["confidence"])
       )}
    end
  end

  defp decode_answer(%Score{levels: levels}, %{"type" => "score", "score" => score} = answer)
       when is_number(score) do
    with {:ok, probabilities} <-
           Dialect.Decision.probabilities(levels, answer["probabilities"], :index) do
      {:ok,
       Answer.Score.new(
         score: float(score),
         probabilities: probabilities,
         confidence: float(answer["confidence"])
       )}
    end
  end

  defp decode_answer(_question, %{"type" => "refusal"}), do: {:ok, Answer.Refusal.new()}
  defp decode_answer(_question, _answer), do: :error

  # Some hosts (Alibaba) report input tokens only.
  defp decode_usage(usage) when is_map(usage) do
    Usage.new(
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0
    )
  end

  defp decode_usage(_usage), do: %Usage{}

  # A wire number as a float (hosts send 1 and 0 as integers); anything else,
  # such as an absent confidence, is nil.
  defp float(number) when is_number(number), do: number * 1.0
  defp float(_other), do: nil
end
