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

  ## Struct fields

    * `:state` — the shared input every question is asked about: a string,
      a map, or a list (anything JSON-encodable)
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
  alias Omni.Question.{Choice, Predicate, Score}

  defstruct [:model, :state, :answers, :usage, :raw, questions: []]

  @typedoc "A decision request, and once answered its result."
  @type t :: %__MODULE__{
          model: Model.t() | nil,
          state: String.t() | map() | list() | nil,
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
  map of fields, or an existing decision (returned as is).

      Omni.Decision.new({"I was charged twice", [refund: Omni.predicate("Is this a refund request?")]})
      Omni.Decision.new(state: %{subject: "Refund"}, questions: [...])

  Does not validate; `Omni.decide/3` does.
  """
  @spec new(t() | {term(), list()} | Enumerable.t()) :: t()
  def new(%__MODULE__{} = decision), do: decision
  def new({state, questions}), do: %__MODULE__{state: state, questions: questions}
  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)

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
  def validate_state(state) when is_binary(state) do
    if String.trim(state) == "", do: {:error, "must not be empty", []}, else: :ok
  end

  def validate_state(state) when is_map(state) or is_list(state) do
    if Enum.empty?(state), do: {:error, "must not be empty", []}, else: :ok
  end

  def validate_state(_state), do: {:error, "must be a string, a map or a list", []}

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

  defp validate_instructions(instructions) when is_binary(instructions) do
    if String.trim(instructions) == "",
      do: {:error, "has empty instructions"},
      else: :ok
  end

  defp validate_instructions(instructions) when is_map(instructions) or is_list(instructions) do
    if Enum.empty?(instructions), do: {:error, "has empty instructions"}, else: :ok
  end

  defp validate_instructions(_instructions),
    do: {:error, "needs instructions: a string, a map or a list"}

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
