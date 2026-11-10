defmodule Omni.Decision do
  @moduledoc """
  A decision: typed questions about a shared state, and their answers.

  The same struct is the request and the result. Build it from a state and
  questions, pass it to `Omni.decide/3`, and get it back with `:answers`,
  `:usage` and `:model` filled in:

      {:ok, decision} =
        Omni.decide({:openrouter, "typesafe/jev-1.14"}, {ticket_text, [
          urgent: Omni.predicate("Does this need a reply within the hour?"),
          team: Omni.choice("Which team owns this?", [:billing, :infra, :other])
        ]})

      decision.answers[:urgent]  #=> %Omni.Answer.Predicate{probability: 0.91}

  `Omni.decide/3` also takes the shorthand `{state, questions}` tuple, as
  above.

  ## State

  The state is the shared input every question is asked about: a list of
  parts, each a `%Omni.Content.Text{}` or `%Omni.Content.Data{}`. `new/1`
  builds them from plain values, so the state can be given as

    * a string — one text part
    * a map — one data part, sent as JSON
    * a list of strings, maps and parts — a part for each, in order

  Anything else (a number, a nested list) is an error when the decision is
  sent. To send an array as data, put it in a map:
  `%{readings: [3, 5, 8]}`. Question instructions are parts in the same way
  (see `Omni.Question`).

      Decision.new({["Ticket from an enterprise customer:", %{subject: "Refund"}], questions})
      #=> %Decision{state: [%Text{text: "Ticket from ..."}, %Data{data: %{"subject" => "Refund"}}], ...}

  ## Struct fields

    * `:state` — the parts every question is asked about (see above)
    * `:questions` — a keyword list of `Omni.Question` structs. The key names
      the question, and the list's order is kept
    * `:answers` — a keyword list aligned with `:questions`, one
      `Omni.Answer` struct per question; `nil` until answered
    * `:usage` — the request's `%Omni.Usage{}`; `nil` until answered
    * `:model` — the `%Omni.Model{}` that answered; `nil` until answered
    * `:raw` — the `{%Req.Request{}, %Req.Response{}}` pair when `decide/3`
      is called with `raw: true`, else `nil`
  """

  alias Omni.{Answer, Model, Question, Usage}
  alias Omni.Content.{Data, Text}
  alias Omni.Question.{Choice, Predicate, Score}

  defstruct [:model, :state, :answers, :usage, :raw, questions: []]

  @typedoc "A part of the state or of a question's instructions."
  @type part :: Text.t() | Data.t()

  @typedoc "A decision request, and once answered its result."
  @type t :: %__MODULE__{
          model: Model.t() | nil,
          state: [part()] | nil,
          questions: [{atom(), Question.t()}],
          answers: [{atom(), Answer.t()}] | nil,
          usage: Usage.t() | nil,
          raw: {Req.Request.t(), Req.Response.t()} | nil
        }

  @schema %{
    state: {:required, {:custom, {__MODULE__, :validate_state}}},
    questions: {:required, {:custom, {__MODULE__, :validate_questions}}}
  }

  @doc """
  Creates a decision from a `{state, questions}` tuple, a keyword list or
  map of fields, or an existing decision.

      Omni.Decision.new({"I was charged twice", [refund: Omni.predicate("Is this a refund request?")]})
      Omni.Decision.new(state: %{subject: "Refund"}, questions: [...])

  The state and every question's instructions are built into parts (see
  [State](#module-state)), which is safe to repeat on an existing decision.
  Raises if a map holds a value JSON can't encode (see
  `Omni.Content.Data.new/1`). Does not validate; `Omni.decide/3` does.
  """
  @spec new(t() | {term(), list()} | Enumerable.t()) :: t()
  def new(%__MODULE__{} = decision) do
    %{decision | state: parts(decision.state), questions: cast_questions(decision.questions)}
  end

  def new({state, questions}), do: new(%__MODULE__{state: state, questions: questions})
  def new(attrs) when is_list(attrs) or is_map(attrs), do: new(struct!(__MODULE__, attrs))

  @doc false
  # Builds parts from a string, a map, a part or a list of them. Values that
  # aren't one are left as they are for validate/1 to reject. Safe to repeat.
  @spec parts(term()) :: term()
  def parts(list) when is_list(list), do: Enum.map(list, &part/1)
  def parts(struct) when is_struct(struct), do: [struct]

  def parts(value) when is_binary(value) or is_map(value), do: [part(value)]
  def parts(other), do: other

  defp part(text) when is_binary(text), do: Text.new(text)
  defp part(map) when is_map(map) and not is_struct(map), do: Data.new(map)
  defp part(other), do: other

  defp cast_questions(questions) when is_list(questions) do
    Enum.map(questions, fn
      {name, %{instructions: _} = question} when is_struct(question) ->
        {name, %{question | instructions: parts(question.instructions)}}

      other ->
        other
    end)
  end

  defp cast_questions(questions), do: questions

  @doc false
  # Checks the shared floor every host accepts: at least one question, each
  # with instructions, and at least two choices or levels. Provider caps (on
  # choices, levels or questions) are left to the provider.
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = decision) do
    case Peri.validate(@schema, %{state: decision.state, questions: decision.questions}) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @doc false
  def validate_state(state) do
    case parts_error(state) do
      nil -> :ok
      message -> {:error, message, []}
    end
  end

  @doc false
  def validate_questions([_ | _] = questions) do
    cond do
      not Keyword.keyword?(questions) ->
        {:error, "must be a keyword list of questions, keyed by name", []}

      length(Enum.uniq(Keyword.keys(questions))) != length(questions) ->
        {:error, "names must be unique", []}

      true ->
        Enum.find_value(questions, :ok, fn {name, question} ->
          case validate_question(question) do
            :ok -> nil
            {:error, message} -> {:error, "question %{name} " <> message, name: name}
          end
        end)
    end
  end

  def validate_questions(_questions),
    do: {:error, "must be a non-empty keyword list of questions", []}

  defp validate_question(%Predicate{instructions: instructions, criteria: criteria}) do
    with :ok <- validate_instructions(instructions), do: validate_criteria(criteria)
  end

  defp validate_question(%Choice{instructions: instructions, choices: choices}) do
    with :ok <- validate_instructions(instructions), do: validate_options(choices, "choices")
  end

  defp validate_question(%Score{instructions: instructions, levels: levels}) do
    with :ok <- validate_instructions(instructions), do: validate_options(levels, "levels")
  end

  defp validate_question(_other),
    do: {:error, "is not a question — build it with Omni.predicate/2, choice/2 or score/2"}

  defp validate_instructions(instructions) do
    case parts_error(instructions) do
      nil -> :ok
      message -> {:error, "instructions " <> message}
    end
  end

  # What is wrong with a list of parts, or nil when nothing is.
  defp parts_error([_ | _] = parts), do: Enum.find_value(parts, &part_error/1)
  defp parts_error([]), do: "must not be empty"
  defp parts_error(_parts), do: "must be a string, a map, or a list of text and data parts"

  defp part_error(%Text{text: text}) when is_binary(text) do
    if String.trim(text) == "", do: "must not have an empty text part"
  end

  defp part_error(%Data{data: data}) when is_map(data) and map_size(data) > 0, do: nil
  defp part_error(%Data{}), do: "must not have an empty data part"

  defp part_error(other),
    do:
      "must hold only text and data parts, got: #{inspect(other, limit: 5, printable_limit: 40)}"

  defp validate_criteria(nil), do: :ok

  defp validate_criteria(criteria) when is_list(criteria) do
    valid? =
      Enum.all?(criteria, &match?({key, text} when is_boolean(key) and is_binary(text), &1)) and
        length(Enum.uniq(Keyword.keys(criteria))) == length(criteria)

    if valid?,
      do: :ok,
      else: {:error, "has invalid criteria — use [true: \"...\", false: \"...\"]"}
  end

  defp validate_criteria(_criteria),
    do: {:error, "has invalid criteria — use [true: \"...\", false: \"...\"]"}

  defp validate_options(options, what) when is_list(options) do
    keys = Enum.map(options, &option_key/1)

    cond do
      Enum.any?(keys, &is_nil/1) ->
        {:error,
         "#{what} must each be a key (an atom or string) or a {key, description} pair, " <>
           "with a string or nil description"}

      length(options) < 2 ->
        {:error, "needs at least two #{what}"}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, "has duplicate #{what} (keys must differ as strings)"}

      true ->
        :ok
    end
  end

  defp validate_options(_options, what), do: {:error, "#{what} must be a list"}

  # The key as a string, or nil when the option is malformed.
  defp option_key({key, description})
       when (is_binary(description) or is_nil(description)) and
              ((is_atom(key) and not is_nil(key)) or (is_binary(key) and key != "")),
       do: to_string(key)

  defp option_key(_option), do: nil
end
