# Records the OpenAI Decisions dialect fixtures from OpenAI. Requests are real
# and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/openai_decisions/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
# The baseline (all three answer types) is in the OpenAI provider fixtures.

alias Omni.Test.{Capture, Cases}

dir = "test/support/fixtures/dialects/openai_decisions"
model = Cases.reference(:openai_decisions)

# -- Cases --

# The same long state twice: turn 2 reads it from the prompt cache.
{decision, opts} = Cases.request(:decision_cache)

with {:ok, _} <- Capture.record(model, decision, "#{dir}/cache_1.json", opts) do
  Capture.record(model, decision, "#{dir}/cache_2.json", Keyword.put(opts, :pause, 2_000))
end
