defmodule Omni.QuestionTest do
  use ExUnit.Case, async: true

  alias Omni.Question
  alias Omni.Question.{Choice, Predicate, Score}

  describe "predicate/2" do
    test "takes instructions and optional criteria" do
      assert %Predicate{instructions: "Is this spam?", criteria: nil} =
               Question.predicate("Is this spam?")

      assert %Predicate{criteria: [true: "Ads", false: "A conversation"]} =
               Question.predicate("Is this spam?", true: "Ads", false: "A conversation")
    end
  end

  describe "choice/2" do
    test "normalises bare keys to pairs with no description" do
      assert %Choice{choices: [{:billing, nil}, {"infra", nil}]} =
               Question.choice("Which team?", [:billing, "infra"])
    end

    test "keeps keyword and tuple pairs, in order" do
      assert %Choice{choices: [billing: "Payments", infra: "Outages", other: nil]} =
               Question.choice("Which team?", billing: "Payments", infra: "Outages", other: nil)

      assert %Choice{choices: [{"a", "First"}, {:b, nil}]} =
               Question.choice("Which?", [{"a", "First"}, :b])
    end
  end

  describe "score/2" do
    test "normalises levels like choices" do
      assert %Score{levels: [{"Calm", nil}, {"Angry", nil}]} =
               Question.score("How angry?", ["Calm", "Angry"])

      assert %Score{levels: [low: "Can wait", high: "Today"]} =
               Question.score("How urgent?", low: "Can wait", high: "Today")
    end
  end

  test "the Omni delegates build the same structs" do
    assert Omni.predicate("x?") == Question.predicate("x?")
    assert Omni.choice("x?", [:a, :b]) == Question.choice("x?", [:a, :b])
    assert Omni.score("x?", [:a, :b]) == Question.score("x?", [:a, :b])
  end
end
