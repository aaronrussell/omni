defmodule Integration.TypeSafeTest do
  use ExUnit.Case, async: true

  import Omni.Test.Baseline

  @dir "test/support/fixtures/typesafe"

  setup do
    {:ok, model} = Omni.get_model(:typesafe, "jev-1.14.0")
    %{model: model}
  end

  describe "baseline" do
    test "decision", %{model: model} do
      {_decision, request} = assert_decision(model, :decision, "#{@dir}/decision.json")

      assert %{"type" => "noul", "criteria" => %{"true" => _, "false" => _}} =
               request.body["questions"]["refund"]
    end

    test "decision json", %{model: model} do
      {_decision, request} = assert_decision(model, :decision_json, "#{@dir}/decision_json.json")

      assert %{"ticket" => %{"subject" => "Site down"}} = request.body["state"]

      assert %{"question" => _, "field" => "ticket.body"} =
               request.body["questions"]["outage"]["instructions"]
    end

    test "target", %{model: model} do
      assert_target(
        model,
        "#{@dir}/decision.json",
        "https://api.typesafe.ai/v1/systemone",
        [{"authorization", "Bearer test-key"}],
        scenario: :decision
      )
    end
  end
end
