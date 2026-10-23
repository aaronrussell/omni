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
