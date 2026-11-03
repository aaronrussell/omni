defmodule Omni.Dialects.OpenAIDecisionsTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.OpenAIDecisions
  alias Omni.{Answer, Decision, Usage}
  alias Omni.Test.Fixtures

  @model Fixtures.model(id: "gpt-6-luna", capability: :decision, dialect: OpenAIDecisions)

  defp decision(state \\ "The login page times out", questions) do
    Decision.new({state, questions})
  end

  defp body(decision, opts \\ %{}), do: OpenAIDecisions.handle_body(@model, decision, opts)

  describe "handle_path/2, auth/0 and option_schema/0" do
    test "posts to /decisions with a bearer key" do
      assert OpenAIDecisions.handle_path(@model, %{}) == "/decisions"
      assert OpenAIDecisions.auth() == :bearer
    end

    test "takes safety_identifier and prompt_cache_key" do
      assert Map.keys(OpenAIDecisions.option_schema()) |> Enum.sort() ==
               [:prompt_cache_key, :safety_identifier]
    end
  end

  describe "handle_body/3" do
    test "sends a string state as input, and questions in order with names" do
      body =
        body(
          decision(
            login: Omni.predicate("Is this a login problem?"),
            team: Omni.choice("Which team?", [:web, :infra])
          )
        )

      assert body["model"] == "gpt-6-luna"
      assert body["input"] == "The login page times out"

      assert [
               %{
                 "type" => "predicate",
                 "name" => "login",
                 "instructions" => "Is this a login problem?"
               },
               %{"type" => "choice", "name" => "team"}
             ] = body["questions"]
    end

    test "sends any other state as one input_json part" do
      questions = [login: Omni.predicate("Login?")]

      json_input = fn data ->
        [%{"role" => "user", "content" => [%{"type" => "input_json", "data" => data}]}]
      end

      assert body(decision(%{subject: "Login"}, questions))["input"] ==
               json_input.(%{subject: "Login"})

      assert body(decision(["a", %{b: 1}], questions))["input"] == json_input.(["a", %{b: 1}])
    end

    test "JSON-encodes map and list instructions" do
      [question] = body(decision(login: Omni.predicate(%{question: "Login?"})))["questions"]
      assert question["instructions"] == ~s({"question":"Login?"})
    end

    test "drops a predicate's criteria" do
      [question] = body(decision(spam: Omni.predicate("Spam?", true: "Ads")))["questions"]
      refute Map.has_key?(question, "criteria")
    end

    test "choices are values and levels labels, as strings, description only when given" do
      [choice, score] =
        body(
          decision(
            priority: Omni.choice("How urgent?", [{:low, "No deadline"}, "high", true]),
            clarity: Omni.score("How clear?", vague: "Hard to act on", clear: nil)
          )
        )["questions"]

      assert choice["choices"] == [
               %{"value" => "low", "description" => "No deadline"},
               %{"value" => "high"},
               %{"value" => "true"}
             ]

      assert score["levels"] == [
               %{"label" => "vague", "description" => "Hard to act on"},
               %{"label" => "clear"}
             ]
    end

    test "adds the dialect's options when given" do
      questions = [login: Omni.predicate("Login?")]

      body =
        body(decision(questions), %{safety_identifier: "user-1", prompt_cache_key: "tickets"})

      assert body["safety_identifier"] == "user-1"
      assert body["prompt_cache_key"] == "tickets"

      refute Map.has_key?(body(decision(questions)), "safety_identifier")
    end
  end

  describe "handle_response/3" do
    @questions [
      refund: Omni.predicate("Refund request?"),
      priority: Omni.choice("How urgent?", [:low, "high", true]),
      clarity: Omni.score("How clear?", ["vague", "clear"])
    ]

    @response %{
      "model" => "gpt-6-luna",
      "answers" => [
        %{"type" => "predicate", "name" => "refund", "probability" => 0.12},
        %{
          "type" => "choice",
          "name" => "priority",
          "choice" => "high",
          "confidence" => 0.7,
          "probabilities" => [
            %{"value" => "low", "probability" => 0.2},
            %{"value" => "high", "probability" => 0.7},
            %{"value" => "true", "probability" => 0.1}
          ]
        },
        %{
          "type" => "score",
          "name" => "clarity",
          "score" => 0.8,
          "confidence" => 0.6,
          "probabilities" => [
            %{"label" => "vague", "value" => 0, "probability" => 0.2},
            %{"label" => "clear", "value" => 1, "probability" => 0.8}
          ]
        }
      ],
      "usage" => %{
        "input_tokens" => 200,
        "input_tokens_details" => %{"cached_tokens" => 150, "cache_write_tokens" => 0},
        "output_tokens" => 0,
        "output_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => 200
      }
    }

    defp respond(body, questions \\ @questions),
      do: OpenAIDecisions.handle_response(body, decision(questions), @model)

    test "maps every answer back to the caller's keys, in the caller's order" do
      assert {:ok, %Decision{answers: answers}} = respond(@response)

      assert answers == [
               refund: %Answer.Predicate{probability: 0.12},
               priority: %Answer.Choice{
                 choice: "high",
                 probabilities: [{:low, 0.2}, {"high", 0.7}, {true, 0.1}],
                 confidence: 0.7
               },
               clarity: %Answer.Score{
                 score: 0.8,
                 probabilities: [{"vague", 0.2}, {"clear", 0.8}],
                 confidence: 0.6
               }
             ]
    end

    test "answers matched by name, whatever their order" do
      body = update_in(@response["answers"], &Enum.reverse/1)
      assert {:ok, %Decision{answers: [refund: _, priority: _, clarity: _]}} = respond(body)
    end

    test "a refusal answers its question; the others are still answered" do
      body =
        put_in(@response["answers"], [
          %{"type" => "refusal", "name" => "refund"} | tl(@response["answers"])
        ])

      assert {:ok,
              %Decision{
                answers: [refund: %Answer.Refusal{}, priority: %Answer.Choice{}, clarity: _]
              }} =
               respond(body)
    end

    test "cached tokens leave input and become cache reads" do
      assert {:ok, %Decision{usage: usage}} = respond(@response)
      assert %Usage{input_tokens: 50, cache_read_tokens: 150, output_tokens: 0} = usage
    end

    test "missing, unasked and mistyped answers are errors" do
      body = update_in(@response["answers"], &tl/1)
      assert respond(body) == {:error, {:invalid_answer, :refund}}

      body =
        update_in(
          @response["answers"],
          &[%{"type" => "predicate", "name" => "x", "probability" => 0.1} | &1]
        )

      assert respond(body) == {:error, {:invalid_answer, "x"}}

      body =
        put_in(@response["answers"], [
          %{"type" => "score", "name" => "refund", "score" => 1} | tl(@response["answers"])
        ])

      assert respond(body) == {:error, {:invalid_answer, :refund}}
    end

    test "a body without answers is an invalid response" do
      assert {:error, {:invalid_response, _}} = respond(%{"error" => %{"message" => "bad"}})
    end
  end
end
