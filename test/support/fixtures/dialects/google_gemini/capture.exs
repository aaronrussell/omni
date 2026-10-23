# Records the Google Gemini dialect fixtures from its home API
# (`Omni.Test.Cases.reference/1`). Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/google_gemini/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture, Cases}

dir = "test/support/fixtures/dialects/google_gemini"
model = Cases.reference(:google_gemini)

# Thinking on with tools: function calls carry thought signatures, which the
# second step must send back with the tool results.
{context, opts} = Baseline.request(:kitchen_sink)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/tools_1.sse", opts) do
  Capture.record(model, Baseline.tool_round(context, resp), "#{dir}/tools_2.sse", opts)
end

# `maxOutputTokens` runs out: `MAX_TOKENS`. Gemini sends each function call
# whole, so there is no tool call to cut short.
{context, opts} = Cases.request(:length)
Capture.record(model, context, "#{dir}/length.sse", opts)
