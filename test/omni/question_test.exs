defmodule Omni.QuestionTest do
  use ExUnit.Case, async: true

  alias Omni.Content.{Data, Text}
  alias Omni.Question
  alias Omni.Question.{Choice, Predicate, Score}

  describe "instructions" do
    test "are built into parts by every constructor" do
      assert %Predicate{instructions: [%Text{text: "Spam?"}]} = Question.predicate("Spam?")

      assert %Choice{instructions: [%Data{data: %{"q" => "Team?"}}]} =
               Question.choice(%{q: "Team?"}, [:a, :b])

      assert %Score{instructions: [%Text{text: "Rate"}, %Data{data: %{"scale" => "anger"}}]} =
               Question.score(["Rate", %{scale: :anger}], [:low, :high])
    end

    test "keep parts as given, and leave anything else for validation" do
      parts = [Text.new("Spam?")]
      assert %Predicate{instructions: ^parts} = Question.predicate(parts)
      assert %Predicate{instructions: nil} = Question.predicate(nil)
      assert %Predicate{instructions: [42]} = Question.predicate([42])
    end
  end

  describe "predicate/2" do
    test "takes instructions and optional criteria" do
      assert %Predicate{instructions: [%Text{text: "Is this spam?"}], criteria: nil} =
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
