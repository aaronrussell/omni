defmodule Omni.Dialect.DecisionTest do
  use ExUnit.Case, async: true

  alias Omni.Answer
  alias Omni.Dialect.Decision
  alias Omni.Question.{Choice, Predicate}

  defp decode(%Predicate{}, %{"p" => p}) when is_number(p),
    do: {:ok, %Answer.Predicate{probability: p * 1.0}}

  defp decode(_question, _wire), do: :error

  describe "decode_answers/3" do
    @questions [a: %Predicate{instructions: []}, b: %Predicate{instructions: []}]

    test "decodes answers in question order" do
      assert {:ok, [a: %Answer.Predicate{probability: 1.0}, b: %Answer.Predicate{}]} =
               Decision.decode_answers(
                 @questions,
                 %{"b" => %{"p" => 0.2}, "a" => %{"p" => 1}},
                 &decode/2
               )
    end

    test "rejects a missing answer by question name" do
      assert Decision.decode_answers(@questions, %{"a" => %{"p" => 1}}, &decode/2) ==
               {:error, {:invalid_answer, :b}}
    end

    test "rejects an answer that doesn't decode" do
      assert Decision.decode_answers(@questions, %{"a" => %{}, "b" => %{"p" => 1}}, &decode/2) ==
               {:error, {:invalid_answer, :a}}
    end

    test "rejects an answer to a question not asked, by its wire name" do
      by_name = %{"a" => %{"p" => 1}, "b" => %{"p" => 1}, "c" => %{"p" => 1}}

      assert Decision.decode_answers(@questions, by_name, &decode/2) ==
               {:error, {:invalid_answer, "c"}}
    end
  end

  describe "choice_key/2" do
    @choices %Choice{instructions: [], choices: [yes: nil, no: "Not at all"]}.choices

    test "maps a wire string to the caller's key" do
      assert Decision.choice_key(@choices, "no") == {:ok, :no}
      assert Decision.choice_key(["1": nil], "1") == {:ok, :"1"}
    end

    test "rejects an unknown or non-string choice" do
      assert Decision.choice_key(@choices, "maybe") == :error
      assert Decision.choice_key(@choices, nil) == :error
    end
  end

  describe "probabilities/3" do
    test "reads a map keyed by option key, in the caller's order, as floats" do
      assert Decision.probabilities([yes: nil, no: nil], %{"no" => 0, "yes" => 1}, :key) ==
               {:ok, [yes: 1.0, no: 0.0]}
    end

    test "reads a map keyed by option index" do
      assert Decision.probabilities([low: nil, high: nil], %{"0" => 0.2, "1" => 0.8}, :index) ==
               {:ok, [low: 0.2, high: 0.8]}
    end

    test "rejects a missing or non-numeric probability" do
      assert Decision.probabilities([yes: nil, no: nil], %{"yes" => 1}, :key) == :error
      assert Decision.probabilities([yes: nil], %{"yes" => "1"}, :key) == :error
      assert Decision.probabilities([yes: nil], nil, :key) == :error
    end
  end
end
