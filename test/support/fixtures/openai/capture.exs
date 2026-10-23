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

{context, opts} = Baseline.request(:structured_output)
Capture.record(model, context, "#{dir}/structured_output.sse", opts)

# -- Cases --

# A real cache hit: turn 2 reads the prefix turn 1 wrote. Responses counts
# cached tokens inside `input_tokens` (`input_tokens_details.cached_tokens`).
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.sse", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.sse", opts)
end
