# Records the Ollama Chat dialect fixtures from its home API, a local Ollama
# (`Omni.Test.Cases.reference/1`). Needs Ollama running on localhost with the
# model pulled (`ollama pull qwen3.8:27b-mlx`).
#
#     MIX_ENV=test mix run test/support/fixtures/dialects/ollama_chat/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture, Cases}

dir = "test/support/fixtures/dialects/ollama_chat"
model = Cases.reference(:ollama_chat)

# Turn 2 reads the prefix turn 1 processed. Ollama reports the cached part as
# `prompt_eval_cached_count`, inside `prompt_eval_count`.
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(model, context, "#{dir}/cache_1.ndjson", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(model, turn2, "#{dir}/cache_2.ndjson", opts)
end

# `num_predict` runs out: `done_reason: "length"`. Ollama sends each tool
# call whole, so there is no tool call to cut short.
{context, opts} = Cases.request(:length)
Capture.record(model, context, "#{dir}/length.ndjson", opts)

# Parallel tool calls, which Ollama sends as one `tool_calls` list.
{context, opts} = Baseline.request(:kitchen_sink)
Capture.record(model, context, "#{dir}/tools_1.ndjson", opts)
