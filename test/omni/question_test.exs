defmodule Omni.QuestionTest do
  use ExUnit.Case, async: true

  alias Omni.Content.{Data, Text}
  alias Omni.Decision
  alias Omni.Question.{Choice, Predicate, Score}

  describe "instructions" do
    test "are built into parts by every constructor" do
      assert %Predicate{instructions: [%Text{text: "Spam?"}]} = Predicate.new("Spam?")

      assert %Choice{instructions: [%Data{data: %{"q" => "Team?"}}]} =
               Choice.new(%{q: "Team?"}, [:a, :b])

      assert %Score{instructions: [%Text{text: "Rate"}, %Data{data: %{"scale" => "anger"}}]} =
               Score.new(["Rate", %{scale: :anger}], [:low, :high])
    end

    test "keep parts as given, and leave anything else for validation" do
      parts = [Text.new("Spam?")]
      assert %Predicate{instructions: ^parts} = Predicate.new(parts, nil)
      assert %Predicate{instructions: nil} = Predicate.new(nil, nil)
      assert %Predicate{instructions: [42]} = Predicate.new([42], nil)
    end
  end

  describe "Predicate.new" do
    test "takes instructions and optional criteria" do
      assert %Predicate{instructions: [%Text{text: "Is this spam?"}], criteria: nil} =
               Predicate.new("Is this spam?")

      assert %Predicate{criteria: [true: "Ads", false: "A conversation"]} =
               Predicate.new("Is this spam?", true: "Ads", false: "A conversation")
    end

    test "takes fields as a keyword list or map" do
      expected = Predicate.new("Is this spam?", true: "Ads")

      assert Predicate.new(instructions: "Is this spam?", criteria: [true: "Ads"]) == expected
      assert Predicate.new(%{instructions: "Is this spam?", criteria: [true: "Ads"]}) == expected
    end
  end

  describe "Choice.new" do
    test "normalises bare keys to pairs with no description" do
      assert %Choice{choices: [{:billing, nil}, {"infra", nil}]} =
               Choice.new("Which team?", [:billing, "infra"])
    end

    test "keeps keyword and tuple pairs, in order" do
      assert %Choice{choices: [billing: "Payments", infra: "Outages", other: nil]} =
               Choice.new("Which team?", billing: "Payments", infra: "Outages", other: nil)

      assert %Choice{choices: [{"a", "First"}, {:b, nil}]} =
               Choice.new("Which?", [{"a", "First"}, :b])
    end

    test "takes fields as a keyword list" do
      assert Choice.new(instructions: "Which?", choices: [:a, :b]) ==
               Choice.new("Which?", [:a, :b])
    end
  end

  describe "Score.new" do
    test "normalises levels like choices" do
      assert %Score{levels: [{"Calm", nil}, {"Angry", nil}]} =
               Score.new("How angry?", ["Calm", "Angry"])

      assert %Score{levels: [low: "Can wait", high: "Today"]} =
               Score.new("How urgent?", low: "Can wait", high: "Today")
    end

    test "takes fields as a keyword list" do
      assert Score.new(instructions: "How?", levels: [:low, :high]) ==
               Score.new("How?", [:low, :high])
    end
  end

  test "constructors are safe to repeat" do
    choice = Choice.new(%{q: "Team?"}, [:a, b: "B"])
    assert Choice.new(Map.from_struct(choice)) == choice
  end

  test "Decision.new casts question literals like the constructors" do
    decision = Decision.new({"state", [team: %Choice{instructions: "Which?", choices: [:a, :b]}]})
    assert decision.questions[:team] == Choice.new("Which?", [:a, :b])
  end

  test "the Omni delegates build the same structs" do
    assert Omni.predicate("x?") == Predicate.new("x?")
    assert Omni.predicate("x?", true: "Yes") == Predicate.new("x?", true: "Yes")
    assert Omni.choice("x?", [:a, :b]) == Choice.new("x?", [:a, :b])
    assert Omni.score("x?", [:a, :b]) == Score.new("x?", [:a, :b])
  end
end
