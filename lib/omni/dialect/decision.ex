defmodule Omni.Dialect.Decision do
  @moduledoc """
  Behaviour for decision dialects.

  A decision dialect turns a `%Omni.Decision{}` (shared state plus typed
  questions) into one JSON request, and reads the JSON response back into
  answers and usage. There is no streaming: the whole response arrives at
  once. Declare it with `use Omni.Dialect, :decision`, which also sets the
  base `Omni.Dialect` behaviour (`c:Omni.Dialect.auth/0`,
  `c:Omni.Dialect.compat_schema/0`).

  ## Implementing a decision dialect

  Like text dialects, decision dialects are stateless and pure: no HTTP, no
  configuration, no side effects.

      defmodule MyApp.Dialects.CustomDecisions do
        use Omni.Dialect, :decision

        alias Omni.{Answer, Decision, Question, Usage}
        alias Omni.Content.{Data, Text}

        @impl true
        def option_schema, do: %{}

        @impl true
        def compat_schema, do: %{}

        @impl true
        def auth, do: :bearer

        @impl true
        def handle_path(_model, _opts), do: "/decide"

        @impl true
        def handle_body(model, %Decision{} = decision, _opts) do
          %{
            "model" => model.id,
            "input" => Enum.map(decision.state, &encode_part/1),
            "questions" => Enum.map(decision.questions, &encode_question/1)
          }
        end

        defp encode_part(%Text{text: text}), do: text
        defp encode_part(%Data{data: data}), do: data

        @impl true
        def handle_response(%{"answers" => answers} = body, %Decision{} = decision, _model) do
          with {:ok, answers} <-
                 Omni.Dialect.Decision.decode_answers(decision.questions, answers, &decode_answer/2) do
            usage = Usage.new(input_tokens: body["usage"]["input_tokens"])
            {:ok, %{decision | answers: answers, usage: usage}}
          end
        end

        defp decode_answer(%Question.Predicate{}, %{"probability" => p}) when is_number(p),
          do: {:ok, %Answer.Predicate{probability: p * 1.0}}

        defp decode_answer(%Question.Choice{choices: choices}, answer) do
          with {:ok, choice} <- Omni.Dialect.Decision.choice_key(choices, answer["choice"]),
               {:ok, probabilities} <-
                 Omni.Dialect.Decision.probabilities(choices, answer["probabilities"], :key) do
            {:ok, %Answer.Choice{choice: choice, probabilities: probabilities}}
          end
        end

        defp decode_answer(_question, _answer), do: :error
      end

  ## Decoding answers

  `decode_answers/3` applies the strict rule every decision dialect follows:
  each question has exactly one answer of its type, and no answer is for a
  question that wasn't asked. Index the wire answers by question name and
  decode one at a time; `choice_key/2` and `probabilities/3` map wire values
  back to the caller's option keys, in the caller's order. Numbers come back
  as floats, since hosts send `1` and `0` as JSON integers.
  """

  alias Omni.{Decision, Model, Question}

  @doc """
  Returns a Peri schema map for dialect-specific options.

  The returned schema is merged with Omni's config options (`:api_key`,
  `:host`, `:headers`, `:timeout`, ...) and validated in a single pass. Text
  generation options such as `:max_tokens` are not part of a decision
  request. Return an empty map if the dialect has no options:

      def option_schema, do: %{safety_identifier: :string}
  """
  @callback option_schema() :: Peri.map_schema()

  @doc """
  Returns the URL path for the given model and options.

  The path is the API's resource path, appended to the base URL of the
  provider's endpoint for the dialect:

      def handle_path(_model, _opts), do: "/systemone"
  """
  @callback handle_path(Model.t(), map()) :: String.t()

  @doc """
  Builds the request body from a model, a decision, and validated options.

  The decision has been validated: its state and every question's
  instructions are non-empty lists of `Omni.Content.Text` and
  `Omni.Content.Data` parts, it has at least one question, and every choice
  or score question has at least two options. Encode each question under a name the response can be matched
  back by. The returned map may be further adjusted by the provider module's
  `c:Omni.Provider.modify_body/4` before being sent as JSON.
  """
  @callback handle_body(Model.t(), Decision.t(), map()) :: map()

  @doc """
  Reads a decoded response body into the decision.

  Fills `:answers` (a keyword list aligned with `decision.questions`, one
  `Omni.Answer` struct per question) and `:usage` (an `%Omni.Usage{}` with
  token counts only; Omni computes costs from the model's pricing). Return
  `{:error, {:invalid_answer, name}}` when an answer is missing, unexpected,
  or of the wrong type for its question.
  """
  @callback handle_response(body :: map(), Decision.t(), Model.t()) ::
              {:ok, Decision.t()} | {:error, term()}

  @doc """
  Decodes wire answers into a keyword list aligned with `questions`.

  `by_name` maps each question name, as a string, to its wire answer;
  `decode` turns one question and its wire answer into `{:ok, answer}` or
  `:error`. Returns `{:error, {:invalid_answer, name}}` for the first
  question without a decodable answer, or for an answer to a question that
  wasn't asked (named by its wire string).

      Omni.Dialect.Decision.decode_answers(
        [ok?: %Omni.Question.Predicate{instructions: []}],
        %{"ok?" => %{"probability" => 1}},
        fn _question, %{"probability" => p} -> {:ok, %Omni.Answer.Predicate{probability: p * 1.0}} end
      )
      #=> {:ok, [ok?: %Omni.Answer.Predicate{probability: 1.0}]}
  """
  @spec decode_answers(
          [{atom(), Question.t()}],
          %{String.t() => map()},
          (Question.t(), map() -> {:ok, Omni.Answer.t()} | :error)
        ) :: {:ok, [{atom(), Omni.Answer.t()}]} | {:error, {:invalid_answer, atom() | String.t()}}
  def decode_answers(questions, by_name, decode) do
    names = Enum.map(questions, fn {name, _question} -> Atom.to_string(name) end)

    case Enum.find(Map.keys(by_name), &(&1 not in names)) do
      nil -> decode_each(questions, by_name, decode)
      extra -> {:error, {:invalid_answer, extra}}
    end
  end

  defp decode_each(questions, by_name, decode) do
    questions
    |> Enum.reduce_while([], fn {name, question}, acc ->
      with %{} = wire <- Map.get(by_name, Atom.to_string(name)),
           {:ok, answer} <- decode.(question, wire) do
        {:cont, [{name, answer} | acc]}
      else
        _ -> {:halt, {:error, {:invalid_answer, name}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      answers -> {:ok, Enum.reverse(answers)}
    end
  end

  @doc """
  Returns the caller's key for a wire choice string.

      Omni.Dialect.Decision.choice_key([yes: nil, no: nil], "no")
      #=> {:ok, :no}
  """
  @spec choice_key([Question.option()], term()) :: {:ok, Question.key()} | :error
  def choice_key(options, wire) when is_binary(wire) do
    case Enum.find(options, fn {key, _desc} -> to_string(key) == wire end) do
      {key, _desc} -> {:ok, key}
      nil -> :error
    end
  end

  def choice_key(_options, _wire), do: :error

  @doc """
  Returns `{key, probability}` for every option, in the caller's order.

  The wire map is keyed by each option's key as a string (`:key`) or by its
  index as a string (`:index`). Every option must have a number.

      Omni.Dialect.Decision.probabilities([yes: nil, no: nil], %{"yes" => 1, "no" => 0}, :key)
      #=> {:ok, [yes: 1.0, no: 0.0]}

      Omni.Dialect.Decision.probabilities([low: nil, high: nil], %{"0" => 0.2, "1" => 0.8}, :index)
      #=> {:ok, [low: 0.2, high: 0.8]}
  """
  @spec probabilities([Question.option()], term(), :key | :index) ::
          {:ok, [{Question.key(), float()}]} | :error
  def probabilities(options, wire, by) when is_map(wire) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {{key, _desc}, index}, acc ->
      wire_key = if by == :key, do: to_string(key), else: Integer.to_string(index)

      case Map.get(wire, wire_key) do
        p when is_number(p) -> {:cont, [{key, p * 1.0} | acc]}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      pairs -> {:ok, Enum.reverse(pairs)}
    end
  end

  def probabilities(_options, _wire, _by), do: :error
end
