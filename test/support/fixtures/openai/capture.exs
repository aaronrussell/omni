# Records the OpenAI fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/openai/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/openai"
{:ok, model} = Omni.get_model(:openai, "gpt-6-luna")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)
