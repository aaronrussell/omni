# Records the TypeSafe fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/typesafe/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/typesafe"
{:ok, model} = Omni.get_model(:typesafe, "jev-1.14.0")

# -- Baseline --

{decision, opts} = Baseline.request(:decision)
Capture.record(model, decision, "#{dir}/decision.json", opts)

{decision, opts} = Baseline.request(:decision_json)
Capture.record(model, decision, "#{dir}/decision_json.json", opts)
