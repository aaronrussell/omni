defmodule Integration.Dialects.OpenAIDecisionsTest do
  use ExUnit.Case, async: true

  alias Omni.Test.{Capture, Cases}

  # Parser paths every provider on the dialect takes, recorded from its home
  # API. The answer types are in the OpenAI provider baseline.
  @dir "test/support/fixtures/dialects/openai_decisions"

  setup do
    %{model: Cases.reference(:openai_decisions)}
  end

  describe "cases" do
    # `input_tokens` includes the cached prefix, reported in
    # `input_tokens_details.cached_tokens`.
    test "cache hit on turn 2", %{model: model} do
      {decision, opts} = Cases.request(:decision_cache)

      assert {:ok, turn1} = Capture.replay(model, decision, "#{@dir}/cache_1.json", opts)
      assert {:ok, turn2} = Capture.replay(model, decision, "#{@dir}/cache_2.json", opts)

      assert turn1.usage.cache_read_tokens == 0
      assert turn2.usage.cache_read_tokens > 0
      assert turn2.usage.input_tokens < turn2.usage.cache_read_tokens
    end
  end
end
