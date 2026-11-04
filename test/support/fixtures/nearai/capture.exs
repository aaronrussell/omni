# Records the NEAR AI fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/nearai/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
#
# No key yet: text, thinking and tool use are recordings from before this
# script, with different prompts.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/nearai"
{:ok, model} = Omni.get_model(:nearai, "z-ai/glm-5.3")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)
