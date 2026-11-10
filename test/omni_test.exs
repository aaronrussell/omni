defmodule OmniTest do
  use ExUnit.Case, async: true
  doctest Omni

  alias Omni.{Context, Message, Model}

  describe "delegates" do
    test "get_model/2 delegates to Model.get/2" do
      {:ok, [%Model{id: model_id} | _]} = Model.list(:anthropic)
      assert {:ok, %Model{id: ^model_id}} = Omni.get_model(:anthropic, model_id)
    end

    test "get_model/2 returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Omni.get_model(:nonexistent, "any")
    end

    test "get_model/1 delegates to Model.get/1" do
      {:ok, [%Model{id: model_id} | _]} = Model.list(:anthropic)
      assert {:ok, %Model{id: ^model_id}} = Omni.get_model("anthropic:#{model_id}")
      assert {:ok, %Model{id: ^model_id}} = Omni.get_model({:anthropic, model_id})
    end

    test "get_provider/1 delegates to Provider.get/1" do
      assert {:ok, %Omni.Provider{id: :anthropic}} = Omni.get_provider(:anthropic)
      assert {:error, {:unknown_provider, :nonexistent}} = Omni.get_provider(:nonexistent)
    end

    test "list_models/1 delegates to Model.list/1" do
      assert {:ok, models} = Omni.list_models(:anthropic)
      assert length(models) > 0
    end

    test "tool/1 delegates to Tool.new/1" do
      tool = Omni.tool(name: "greet", description: "Says hello", handler: &String.upcase/1)
      assert %Omni.Tool{name: "greet", description: "Says hello"} = tool
    end

    test "context/1 delegates to Context.new/1" do
      assert %Context{messages: [%Message{role: :user}]} = Omni.context("Hello")
    end

    test "message/1 delegates to Message.new/1" do
      assert %Message{role: :user, content: [%Omni.Content.Text{text: "Hi"}]} =
               Omni.message("Hi")
    end
  end

  describe "decide/3" do
    alias Omni.{Answer, Decision}
    alias Omni.Test.Fixtures

    @answers %{
      "answers" => %{
        "urgent" => %{"type" => "noul", "noul" => 0.91},
        "team" => %{
          "type" => "choice",
          "choice" => "infra",
          "confidence" => 0.93,
          "probabilities" => %{"billing" => 0.02, "infra" => 0.95, "other" => 0.03}
        }
      },
      "usage" => %{"input_tokens" => 174, "output_tokens" => 0}
    }

    @questions [
      urgent: Omni.predicate("Does this need a reply within the hour?"),
      team:
        Omni.choice("Which team owns this?", billing: "Payments", infra: "Outages", other: nil)
    ]

    defp decision_model do
      Fixtures.model(
        id: "jev-1.14",
        capability: :decision,
        dialect: Omni.Dialects.TypeSafeSystemOne,
        input_cost: 0.042
      )
    end

    defp stub(name) do
      Req.Test.stub(name, fn conn -> Req.Test.json(conn, @answers) end)
      {Req.Test, name}
    end

    test "answers a {state, questions} shorthand" do
      assert {:ok, %Decision{} = decision} =
               Omni.decide(decision_model(), {"The site is down", @questions},
                 plug: stub(:decide)
               )

      assert decision.state == [%Omni.Content.Text{text: "The site is down"}]
      assert decision.questions == @questions
      assert decision.answers[:urgent] == %Answer.Predicate{probability: 0.91}

      assert %Answer.Choice{
               choice: :infra,
               probabilities: [billing: 0.02, infra: 0.95, other: 0.03]
             } =
               decision.answers[:team]

      assert decision.usage.input_tokens == 174
      assert decision.usage.total_cost > 0
    end

    test "answers a %Decision{} and attaches raw on request" do
      decision = Decision.new(state: %{subject: "Outage"}, questions: @questions)

      assert {:ok, %Decision{raw: {%Req.Request{}, %Req.Response{}}}} =
               Omni.decide(decision_model(), decision, plug: stub(:decide_raw), raw: true)
    end

    test "a text model can't decide, and a decision model can't generate text" do
      {:ok, [text_model | _]} = Model.list(:anthropic)

      assert Omni.decide(text_model, {"x", @questions}) ==
               {:error, {:unsupported_capability, :decision}}

      assert Omni.generate_text(decision_model(), "Hello") ==
               {:error, {:unsupported_capability, :text}}
    end

    test "an unknown model is an error" do
      assert {:error, {:unknown_model, :anthropic, "nope"}} =
               Omni.decide({:anthropic, "nope"}, {"x", @questions})
    end
  end
end
