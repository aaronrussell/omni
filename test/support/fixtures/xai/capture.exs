# Records the xAI fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/xai/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
# Recorded on grok-4.3, the cheapest reasoning model and the only one with a
# "none" effort, so the text request switches thinking off.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/xai"
{:ok, model} = Omni.get_model(:xai, "grok-4.3")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)
