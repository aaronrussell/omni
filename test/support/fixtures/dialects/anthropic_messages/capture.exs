# Records the Anthropic Messages dialect fixtures from its home API
# (`Omni.Test.Cases.reference/1`). Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/anthropic_messages/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture, Cases}

dir = "test/support/fixtures/dialects/anthropic_messages"
model = Cases.reference(:anthropic_messages)

# A real cache hit: turn 2 reads the prefix turn 1 wrote. Anthropic's
# `input_tokens` excludes cached tokens.
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.sse", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.sse", opts)
end

# `max_tokens` runs out partway through a tool call's arguments.
{context, opts} = Cases.request(:tool_length)
Capture.record(model, context, "#{dir}/tool_length.sse", opts)

# Thinking on with tools: signed thinking, then tool use. The second step
# sends the thinking back ahead of the calls.
{context, opts} = Cases.request(:thinking_tools)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/tools_1.sse", opts) do
  Capture.record(model, Baseline.tool_round(context, resp), "#{dir}/tools_2.sse", opts)
end

# Anthropic's documented trigger for `redacted_thinking` blocks. Haiku 5.5
# returned three. If a re-recording returns none, the trigger has stopped
# working: drop the case.
{context, opts} = Cases.request(:redacted_thinking)
Capture.record(model, context, "#{dir}/redacted_thinking.sse", opts)
