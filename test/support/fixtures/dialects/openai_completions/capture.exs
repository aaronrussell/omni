# Records the OpenAI Completions dialect fixtures from its home API, OpenAI's
# own `/chat/completions` (`Omni.Test.Cases.reference/1`). Requests are real
# and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/openai_completions/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture, Cases}

dir = "test/support/fixtures/dialects/openai_completions"
model = Cases.reference(:openai_completions)

# A real cache hit: turn 2 reads the prefix turn 1 wrote. Completions counts
# cached tokens inside `prompt_tokens` (`prompt_tokens_details.cached_tokens`).
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.sse", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.sse", opts)
end

# `max_completion_tokens` runs out partway through a tool call's arguments.
{context, opts} = Cases.request(:tool_length)
Capture.record(model, context, "#{dir}/tool_length.sse", opts)

# Parallel tool calls: the reference shape the providers' discovery fixtures
# are compared with. Thinking off: OpenAI's `/chat/completions` rejects tools
# with a `reasoning_effort` other than "none" on gpt-6-luna.
{context, opts} = Baseline.request(:kitchen_sink)
opts = Keyword.put(opts, :thinking, false)
Capture.record(model, context, "#{dir}/tools_1.sse", opts)
