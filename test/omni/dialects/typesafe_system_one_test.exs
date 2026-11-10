defmodule Omni.Dialects.TypeSafeSystemOneTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.TypeSafeSystemOne
  alias Omni.{Answer, Decision, Usage}
  alias Omni.Test.Fixtures

  @model Fixtures.model(id: "jev-1.14", capability: :decision, dialect: TypeSafeSystemOne)

  defp decision(state \\ "I was charged twice", questions) do
    Decision.new({state, questions})
  end

  defp body(decision), do: TypeSafeSystemOne.handle_body(@model, decision, %{})

  describe "handle_path/2 and auth/0" do
    test "posts to /systemone with a bearer key" do
      assert TypeSafeSystemOne.handle_path(@model, %{}) == "/systemone"
      assert TypeSafeSystemOne.auth() == :bearer
    end
  end

  describe "handle_body/3" do
    test "sends the model, the state as given, and questions keyed by name" do
      body = body(decision(urgent: Omni.predicate("Urgent?")))

      assert body == %{
               "model" => "jev-1.14",
               "state" => "I was charged twice",
               "questions" => %{"urgent" => %{"type" => "noul", "instructions" => "Urgent?"}}
             }
    end

    test "sends map and list states natively" do
      questions = [urgent: Omni.predicate("Urgent?")]

      assert body(decision(%{subject: "Refund"}, questions))["state"] == %{subject: "Refund"}
      assert body(decision(["a", %{b: 1}], questions))["state"] == ["a", %{b: 1}]
    end

    test "a predicate's criteria become true and false descriptions" do
      body = body(decision(spam: Omni.predicate("Spam?", true: "Ads", false: "A conversation")))

      assert body["questions"]["spam"]["criteria"] == %{
               "true" => "Ads",
               "false" => "A conversation"
             }

      body = body(decision(spam: Omni.predicate("Spam?", true: "Ads")))
      assert body["questions"]["spam"]["criteria"] == %{"true" => "Ads"}
    end

    test "choices are a map of key to description, nil when undescribed" do
      body = body(decision(team: Omni.choice("Which team?", billing: "Payments", other: nil)))

      assert body["questions"]["team"] == %{
               "type" => "choice",
               "instructions" => "Which team?",
               "criteria" => %{"billing" => "Payments", "other" => nil}
             }
    end

    test "levels are a list of descriptions, the key standing in for a missing one" do
      body =
        body(
          decision(urgency: Omni.score("How urgent?", low: "Can wait", mid: nil, high: "Today"))
        )

      assert body["questions"]["urgency"] == %{
               "type" => "score",
               "instructions" => "How urgent?",
               "criteria" => ["Can wait", "mid", "Today"]
             }
    end

    test "instructions are sent as given, JSON included" do
      body = body(decision(urgent: Omni.predicate(%{question: "Urgent?", context: "support"})))

      assert body["questions"]["urgent"]["instructions"] == %{
               question: "Urgent?",
               context: "support"
             }
    end
  end

  describe "handle_response/3" do
    @questions [
      urgent: Omni.predicate("Urgent?"),
      team: Omni.choice("Which team?", [:billing, "infra", :other]),
      anger: Omni.score("How angry?", calm: "Calm", cross: "Cross", furious: "Furious")
    ]

    @response %{
      "model" => "jev-1.14",
      "answers" => %{
        "urgent" => %{"type" => "noul", "noul" => 0.91},
        "team" => %{
          "type" => "choice",
          "choice" => "infra",
          "confidence" => 0.93,
          "probabilities" => %{"billing" => 0.02, "infra" => 0.95, "other" => 0.03}
        },
        "anger" => %{
          "type" => "score",
          "score" => 1.4,
          "confidence" => 0.4,
          "legend" => %{"0" => "Calm", "1" => "Cross", "2" => "Furious"},
          "probabilities" => %{"0" => 0.1, "1" => 0.4, "2" => 0.5}
        }
      },
      "usage" => %{"input_tokens" => 174, "output_tokens" => 12}
    }

    defp respond(body, questions \\ @questions),
      do: TypeSafeSystemOne.handle_response(body, decision(questions), @model)

    test "maps every answer back to the caller's keys, in the caller's order" do
      assert {:ok, %Decision{answers: answers}} = respond(@response)

      assert answers == [
               urgent: %Answer.Predicate{probability: 0.91},
               team: %Answer.Choice{
                 choice: "infra",
                 probabilities: [{:billing, 0.02}, {"infra", 0.95}, {:other, 0.03}],
                 confidence: 0.93
               },
               anger: %Answer.Score{
                 score: 1.4,
                 probabilities: [calm: 0.1, cross: 0.4, furious: 0.5],
                 confidence: 0.4
               }
             ]
    end

    # Ollama sends certain answers as JSON integers.
    test "whole-number probabilities, scores and confidences come back as floats" do
      body = %{
        @response
        | "answers" => %{
            "urgent" => %{"type" => "noul", "noul" => 1},
            "team" => %{
              "type" => "choice",
              "choice" => "infra",
              "confidence" => 1,
              "probabilities" => %{"billing" => 0, "infra" => 1, "other" => 0}
            },
            "anger" => %{
              "type" => "score",
              "score" => 2,
              "confidence" => 1,
              "probabilities" => %{"0" => 0, "1" => 0, "2" => 1}
            }
          }
      }

      assert {:ok, %Decision{answers: answers}} = respond(body)

      assert [
               urgent: %Answer.Predicate{probability: 1.0},
               team: %Answer.Choice{
                 probabilities: [{:billing, +0.0}, {"infra", 1.0}, {:other, +0.0}],
                 confidence: 1.0
               },
               anger: %Answer.Score{
                 score: 2.0,
                 probabilities: [calm: +0.0, cross: +0.0, furious: 1.0],
                 confidence: 1.0
               }
             ] = answers
    end

    test "reads usage as token counts, input only when output is missing" do
      assert {:ok, %Decision{usage: %Usage{input_tokens: 174, output_tokens: 12}}} =
               respond(@response)

      body = %{@response | "usage" => %{"input_tokens" => 50}}
      assert {:ok, %Decision{usage: %Usage{input_tokens: 50, output_tokens: 0}}} = respond(body)

      body = Map.delete(@response, "usage")
      assert {:ok, %Decision{usage: %Usage{input_tokens: 0}}} = respond(body)
    end

    test "ignores extra top-level fields (OpenRouter's id, provider and cost)" do
      body = Map.merge(@response, %{"id" => "gen-1", "provider" => "TypeSafe"})
      assert {:ok, %Decision{}} = respond(body)
    end

    test "a missing answer is an error" do
      body = update_in(@response["answers"], &Map.delete(&1, "team"))
      assert respond(body) == {:error, {:invalid_answer, :team}}
    end

    test "an answer for a question not asked is an error" do
      body = put_in(@response["answers"]["extra"], %{"type" => "noul", "noul" => 0.5})
      assert respond(body) == {:error, {:invalid_answer, "extra"}}
    end

    test "an answer of the wrong type is an error" do
      body = put_in(@response["answers"]["urgent"], %{"type" => "score", "score" => 1})
      assert respond(body) == {:error, {:invalid_answer, :urgent}}
    end

    test "an unknown choice, or a missing probability, is an error" do
      body = put_in(@response["answers"]["team"]["choice"], "legal")
      assert respond(body) == {:error, {:invalid_answer, :team}}

      body = update_in(@response["answers"]["anger"]["probabilities"], &Map.delete(&1, "2"))
      assert respond(body) == {:error, {:invalid_answer, :anger}}
    end

    test "a body without answers is an invalid response" do
      assert respond(%{"detail" => "nope"}) ==
               {:error, {:invalid_response, %{"detail" => "nope"}}}
    end
  end
end
