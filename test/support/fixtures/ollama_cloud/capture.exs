# Records the Ollama Cloud fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/ollama_cloud/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/ollama_cloud"
{:ok, model} = Omni.get_model(:ollama_cloud, "gemma4:31b")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.ndjson", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.ndjson", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.ndjson", opts)

# No structured output: Ollama Cloud doesn't enforce `format`.

# -- Cases --

# Turn 2 reads the prefix turn 1 processed. Ollama reports the cached part as
# `prompt_eval_cached_count`, inside `prompt_eval_count`.
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.ndjson", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.ndjson", opts)
end
