# Records the Moonshot fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/moonshotai/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
# Moonshot allows a few requests a minute, so each live request waits first.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/moonshotai"
{:ok, model} = Omni.get_model(:moonshotai, "kimi-k3")
pause = [pause: 25_000]

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts ++ pause)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts ++ pause)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts ++ pause)

{context, opts} = Baseline.request(:structured_output)
Capture.record(model, context, "#{dir}/structured_output.sse", opts ++ pause)

# -- Cases --

# A real cache hit: turn 2 reads the prefix turn 1 wrote. Completions counts
# cached tokens inside `prompt_tokens` (`prompt_tokens_details.cached_tokens`).
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.sse", opts ++ pause) do
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.sse", opts ++ pause)
end
