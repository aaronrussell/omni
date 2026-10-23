# Records the OpenAI Responses dialect fixtures from its home API
# (`Omni.Test.Cases.reference/1`). Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/openai_responses/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture, Cases}

dir = "test/support/fixtures/dialects/openai_responses"
model = Cases.reference(:openai_responses)

# A real cache hit: turn 2 reads the prefix turn 1 wrote. Responses counts
# cached tokens inside `input_tokens` (`input_tokens_details.cached_tokens`).
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.sse", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.sse", opts)
end

# `max_output_tokens` runs out partway through a tool call's arguments: the
# stream ends with `response.incomplete`, not `response.completed`.
{context, opts} = Cases.request(:tool_length)
Capture.record(model, context, "#{dir}/tool_length.sse", opts)

# Thinking on with tools: reasoning items, then parallel function calls. The
# second step sends the reasoning items back with the tool results.
{context, opts} = Cases.request(:thinking_tools)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/tools_1.sse", opts) do
  Capture.record(model, Baseline.tool_round(context, resp), "#{dir}/tools_2.sse", opts)
end
