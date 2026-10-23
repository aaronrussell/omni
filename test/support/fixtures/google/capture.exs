# Records the Google fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/google/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/google"
{:ok, model} = Omni.get_model(:google, "gemini-3.8-flash")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)

{context, opts} = Baseline.request(:structured_output)
Capture.record(model, context, "#{dir}/structured_output.sse", opts)

# -- Cases --

# Thinking on with tools: function calls carry thought signatures, which the
# second step must send back with the tool results.
{context, opts} = Baseline.request(:kitchen_sink)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/tools_1.sse", opts) do
  Capture.record(model, Baseline.tool_round(context, resp), "#{dir}/tools_2.sse", opts)
end
