# Records the local Ollama fixtures. Needs Ollama running on localhost with
# the model pulled (`ollama pull qwen3.8:27b-mlx`).
#
#     MIX_ENV=test mix run test/support/fixtures/ollama/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/ollama"

# Local models aren't in the catalog.
model =
  Omni.Model.new(
    id: "qwen3.8:27b-mlx",
    name: "qwen3.8:27b-mlx",
    provider: :ollama,
    thinking: true
  )

:ok = Omni.put_model(model)

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.ndjson", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.ndjson", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.ndjson", opts)
