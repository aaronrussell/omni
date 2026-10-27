# Records the Mistral fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/mistral/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
# Recorded on the free tier, which serves Ministral but no reasoning model, so
# there is no thinking fixture here: Mistral's thinking chunks are recorded
# through OpenCode Zen (fixtures/opencode/mistral_thinking.sse). The free tier
# allows about a request a second, so each live request waits first.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/mistral"
{:ok, model} = Omni.get_model(:mistral, "ministral-8b-2512")
pause = [pause: 2_000]

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts ++ pause)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts ++ pause)
