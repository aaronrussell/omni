# Records the Together AI fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/togetherai/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
# Recorded on Qwen3.5 9B, the cheapest hybrid reasoning model, which switches
# with `reasoning: {enabled: ...}`, so the text request switches thinking off.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/togetherai"
{:ok, model} = Omni.get_model(:togetherai, "Qwen/Qwen3.5-9B")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)
