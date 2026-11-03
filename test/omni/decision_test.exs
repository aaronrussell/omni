defmodule Omni.DecisionTest do
  use ExUnit.Case, async: true

  alias Omni.Decision

  @questions [refund: Omni.predicate("Is this a refund request?")]

  describe "new/1" do
    test "builds from a {state, questions} tuple" do
      assert %Decision{state: "ticket", questions: @questions, answers: nil} =
               Decision.new({"ticket", @questions})
    end

    test "builds from a keyword list or map" do
      assert %Decision{state: %{a: 1}, questions: @questions} =
               Decision.new(state: %{a: 1}, questions: @questions)

      assert %Decision{state: ["a"]} = Decision.new(%{state: ["a"], questions: @questions})
    end

    test "returns a decision as is" do
      decision = Decision.new({"ticket", @questions})
      assert Decision.new(decision) == decision
    end
  end

  describe "validate/1" do
    defp validate(state, questions), do: Decision.validate(Decision.new({state, questions}))

    defp message({:error, [%Peri.Error{message: message}]}), do: message

    test "accepts every question type, and string, map and list states" do
      questions = [
        urgent: Omni.predicate("Urgent?", true: "Within the hour", false: "Can wait"),
        team: Omni.choice("Which team?", billing: "Payments", infra: nil),
        anger: Omni.score("How angry?", ["Calm", "Angry"]),
        json: Omni.predicate(%{"question" => "Urgent?"})
      ]

      assert :ok = validate("ticket", questions)
      assert :ok = validate(%{subject: "Refund"}, questions)
      assert :ok = validate(["ticket", %{order: 1}], questions)
    end

    test "rejects an empty or missing state" do
      assert message(validate("  ", @questions)) =~ "must not be empty"
      assert message(validate(%{}, @questions)) =~ "must not be empty"
      assert message(validate(nil, @questions)) =~ "required"
      assert message(validate(42, @questions)) =~ "a string, a map or a list"
    end

    test "rejects no questions, or questions not keyed by name" do
      assert message(validate("x", [])) =~ "non-empty keyword list"
      assert message(validate("x", [Omni.predicate("x?")])) =~ "keyword list of questions"

      assert message(validate("x", [{"refund", Omni.predicate("x?")}])) =~
               "keyword list of questions"
    end

    test "rejects duplicate names" do
      assert message(validate("x", a: Omni.predicate("x?"), a: Omni.predicate("y?"))) =~
               "names must be unique"
    end

    test "rejects empty instructions" do
      assert message(validate("x", a: Omni.predicate(""))) =~ "question :a has empty instructions"
      assert message(validate("x", a: Omni.choice([], [:x, :y]))) =~ "empty instructions"
      assert message(validate("x", a: Omni.predicate(nil))) =~ "needs instructions"
    end

    test "rejects fewer than two choices or levels" do
      assert message(validate("x", a: Omni.choice("x?", [:one]))) =~
               "question :a needs at least two choices"

      assert message(validate("x", a: Omni.score("x?", ["one"]))) =~ "at least two levels"
    end

    test "rejects keys that collide as strings" do
      assert message(validate("x", a: Omni.choice("x?", [:yes, "yes"]))) =~ "duplicate choices"
    end

    test "rejects malformed options" do
      assert message(validate("x", a: Omni.choice("x?", [:yes, {:no, 1}]))) =~
               "{key, description} pair"

      assert message(validate("x", a: Omni.choice("x?", [nil, :yes]))) =~ "{key, description}"
      assert message(validate("x", a: Omni.choice("x?", ["", :yes]))) =~ "{key, description}"
      assert message(validate("x", a: Omni.choice("x?", %{yes: nil}))) =~ "choices must be a list"
    end

    test "rejects criteria other than true and false" do
      assert message(validate("x", a: Omni.predicate("x?", maybe: "Unsure"))) =~
               "invalid criteria"

      assert message(validate("x", a: Omni.predicate("x?", true: 1))) =~ "invalid criteria"
      assert message(validate("x", a: Omni.predicate("x?", "yes"))) =~ "invalid criteria"
    end

    test "rejects a value that is not a question" do
      assert message(validate("x", a: "Is this spam?")) =~ "is not a question"
    end
  end
end
