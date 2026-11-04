defmodule Omni.Dialects.OpenAIDecisions do
  @moduledoc """
  Dialect implementation for the OpenAI Decisions format.

  OpenAI's Decisions API (`POST /v1/decisions`), served by `gpt-6-luna`. See
  `Omni.Dialect.Decision` for the behaviour.

  ## Encoding

    * A string state is sent as `input`. Anything else (a map or a list) is
      sent as one `input_json` part of a user message.
    * Questions are sent in order, each named by its key. Instructions that
      are a map or list are JSON-encoded, since the API takes text there.
    * Choices are sent as `{value, description}` and levels as
      `{label, description}`, keys as strings.
    * Predicate criteria have no field in this API and are dropped.

  ## Answers

  Probabilities are mapped back to the question's keys, in the question's
  order. A refused question is answered with `%Omni.Answer.Refusal{}`; the
  others are still answered.

  ## Options

    * `:safety_identifier` — a stable identifier for the end user, for
      OpenAI's abuse detection
    * `:prompt_cache_key` — groups requests that share a prefix for caching

  ## Compat flags

  None.
  """

  use Omni.Dialect, :decision

  alias Omni.{Answer, Decision, Model, Usage}
  alias Omni.Dialect.Decision.Answers
  alias Omni.Question.{Choice, Predicate, Score}

  import Omni.Util, only: [maybe_put: 3]

  @impl true
  def option_schema, do: %{safety_identifier: :string, prompt_cache_key: :string}

  @impl true
  def compat_schema, do: %{}

  @impl true
  def auth, do: :bearer

  @impl true
  def handle_path(%Model{}, _opts), do: "/decisions"

  @impl true
  def handle_body(%Model{} = model, %Decision{} = decision, opts) do
    %{
      "model" => model.id,
      "input" => encode_input(decision.state),
      "questions" => Enum.map(decision.questions, &encode_question/1)
    }
    |> maybe_put("safety_identifier", opts[:safety_identifier])
    |> maybe_put("prompt_cache_key", opts[:prompt_cache_key])
  end

  @impl true
  def handle_response(%{"answers" => answers} = body, %Decision{} = decision, %Model{})
      when is_list(answers) do
    by_name = Map.new(answers, fn answer -> {answer["name"], answer} end)

    with {:ok, answers} <- Answers.decode(decision.questions, by_name, &decode_answer/2) do
      {:ok, %{decision | answers: answers, usage: decode_usage(body["usage"])}}
    end
  end

  def handle_response(body, %Decision{}, %Model{}), do: {:error, {:invalid_response, body}}

  # -- Encoding --

  defp encode_input(state) when is_binary(state), do: state

  defp encode_input(state) do
    [%{"role" => "user", "content" => [%{"type" => "input_json", "data" => state}]}]
  end

  defp encode_question({name, question}) do
    %{
      "name" => Atom.to_string(name),
      "instructions" => encode_instructions(question.instructions)
    }
    |> Map.merge(encode_type(question))
  end

  defp encode_type(%Predicate{}), do: %{"type" => "predicate"}

  defp encode_type(%Choice{choices: choices}) do
    %{"type" => "choice", "choices" => Enum.map(choices, &encode_option(&1, "value"))}
  end

  defp encode_type(%Score{levels: levels}) do
    %{"type" => "score", "levels" => Enum.map(levels, &encode_option(&1, "label"))}
  end

  defp encode_option({key, description}, field) do
    maybe_put(%{field => to_string(key)}, "description", description)
  end

  defp encode_instructions(instructions) when is_binary(instructions), do: instructions
  defp encode_instructions(instructions), do: JSON.encode!(instructions)

  # -- Decoding --

  defp decode_answer(_question, %{"type" => "refusal"}), do: {:ok, %Answer.Refusal{}}

  defp decode_answer(%Predicate{}, %{"type" => "predicate", "probability" => probability})
       when is_number(probability),
       do: {:ok, %Answer.Predicate{probability: Answers.float(probability)}}

  defp decode_answer(%Choice{choices: choices}, %{"type" => "choice"} = answer) do
    wire = by_field(answer["probabilities"], "value")

    with {:ok, choice} <- Answers.key(choices, answer["choice"]),
         {:ok, probabilities} <- Answers.probabilities(choices, wire, :key) do
      {:ok,
       %Answer.Choice{
         choice: choice,
         probabilities: probabilities,
         confidence: Answers.float(answer["confidence"])
       }}
    end
  end

  defp decode_answer(%Score{levels: levels}, %{"type" => "score", "score" => score} = answer)
       when is_number(score) do
    wire = by_field(answer["probabilities"], "value")

    with {:ok, probabilities} <- Answers.probabilities(levels, wire, :index) do
      {:ok,
       %Answer.Score{
         score: Answers.float(score),
         probabilities: probabilities,
         confidence: Answers.float(answer["confidence"])
       }}
    end
  end

  defp decode_answer(_question, _answer), do: :error

  # `[%{"value" => v, "probability" => p}]` as `%{to_string(v) => p}`: choice
  # values are the strings Omni sent, level values their indices.
  defp by_field(probabilities, field) when is_list(probabilities) do
    Map.new(probabilities, fn entry -> {to_string(entry[field]), entry["probability"]} end)
  end

  defp by_field(_probabilities, _field), do: nil

  # `input_tokens` includes cached tokens; Omni's doesn't. Cache writes stay
  # in input, as OpenAI bills them at the input rate.
  defp decode_usage(usage) when is_map(usage) do
    input = usage["input_tokens"] || 0
    cached = get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0

    Usage.new(
      input_tokens: input - cached,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: cached
    )
  end

  defp decode_usage(_usage), do: %Usage{}
end
