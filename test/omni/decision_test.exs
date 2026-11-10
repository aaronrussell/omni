defmodule Omni.DecisionTest do
  use ExUnit.Case, async: true

  alias Omni.Content.{Data, Text}
  alias Omni.Decision
  alias Omni.Question.Predicate

  @questions [refund: Omni.predicate("Is this a refund request?")]

  describe "new/1" do
    test "builds from a {state, questions} tuple" do
      assert %Decision{state: [%Text{text: "ticket"}], questions: @questions, answers: nil} =
               Decision.new({"ticket", @questions})
    end

    test "builds from a keyword list or map" do
      assert %Decision{state: [%Data{data: %{"a" => 1}}], questions: @questions} =
               Decision.new(state: %{a: 1}, questions: @questions)

      assert %Decision{state: [%Text{text: "a"}]} =
               Decision.new(%{state: ["a"], questions: @questions})
    end

    test "builds the state into parts: a string text, a map data, a list one per item" do
      assert %Decision{state: [%Text{text: "ticket"}, %Data{data: %{"plan" => "pro"}}]} =
               Decision.new({["ticket", %{plan: :pro}], @questions})

      parts = [Text.new("ticket"), Data.new(%{a: 1})]
      assert %Decision{state: ^parts} = Decision.new({parts, @questions})
      assert %Decision{state: [%Text{text: "one"}]} = Decision.new({Text.new("one"), @questions})
    end

    test "leaves anything else in the state for validation" do
      assert %Decision{state: nil} = Decision.new({nil, @questions})
      assert %Decision{state: 42} = Decision.new({42, @questions})

      assert %Decision{state: [%Text{text: "a"}, 1, ["b"]]} =
               Decision.new({["a", 1, ["b"]], @questions})
    end

    test "builds instructions into parts, including on struct literals" do
      questions = [urgent: %Predicate{instructions: "Urgent?"}]

      assert %Decision{questions: [urgent: %Predicate{instructions: [%Text{text: "Urgent?"}]}]} =
               Decision.new({"ticket", questions})
    end

    test "builds an existing decision's parts, and is safe to repeat" do
      literal = %Decision{state: "ticket", questions: @questions}
      decision = Decision.new(literal)

      assert decision.state == [%Text{text: "ticket"}]
      assert Decision.new(decision) == decision
    end

    test "raises on a map JSON can't encode" do
      assert_raise Protocol.UndefinedError, fn -> Decision.new({%{at: {1, 2}}, @questions}) end
    end
  end

  describe "validate/1" do
    defp validate(state, questions), do: Decision.validate(Decision.new({state, questions}))

    defp message({:error, [%Peri.Error{message: message}]}), do: message

    test "accepts every question type, and states built from strings, maps and lists" do
      questions = [
        urgent: Omni.predicate("Urgent?", true: "Within the hour", false: "Can wait"),
        team: Omni.choice("Which team?", billing: "Payments", infra: nil),
        anger: Omni.score("How angry?", ["Calm", "Angry"]),
        json: Omni.predicate(%{"question" => "Urgent?"})
      ]

      assert :ok = validate("ticket", questions)
      assert :ok = validate(%{subject: "Refund"}, questions)
      assert :ok = validate(["ticket", %{order: 1}], questions)
      assert :ok = validate([Text.new("ticket"), %{order: 1}], questions)
    end

    test "rejects an empty or missing state" do
      assert message(validate([], @questions)) =~ "must not be empty"
      assert message(validate("  ", @questions)) =~ "must not have an empty text part"
      assert message(validate(%{}, @questions)) =~ "must not have an empty data part"
      assert message(validate(nil, @questions)) =~ "required"
    end

    test "rejects a state that isn't parts" do
      assert message(validate(42, @questions)) =~
               "a string, a map, or a list of text and data parts"

      assert message(validate(["ticket", 42], @questions)) =~ "only text and data parts, got: 42"
      assert message(validate([["a"]], @questions)) =~ "only text and data parts"

      attachment = Omni.Content.Attachment.new(source: {:base64, "AA=="}, media_type: "image/png")
      assert message(validate([attachment], @questions)) =~ "only text and data parts"
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

    test "rejects empty or missing instructions" do
      assert message(validate("x", a: Omni.predicate(""))) =~
               "question :a instructions must not have an empty text part"

      assert message(validate("x", a: Omni.choice([], [:x, :y]))) =~
               "instructions must not be empty"

      assert message(validate("x", a: Omni.predicate(nil))) =~
               "instructions must be a string, a map, or a list of text and data parts"

      assert message(validate("x", a: Omni.predicate(["Spam?", true]))) =~
               "instructions must hold only text and data parts, got: true"
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
