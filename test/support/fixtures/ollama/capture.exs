# Records the local Ollama fixtures. Needs Ollama running on localhost with
# the models pulled (`ollama pull qwen3.8:27b-mlx`,
# `ollama pull pplx-decider-flash:4b-nvfp4`).
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
    dialects: %{text: Omni.Dialects.OllamaChat},
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

# -- Baseline: decisions --

decision_model =
  Omni.Model.new(
    id: "pplx-decider-flash:4b-nvfp4",
    name: "pplx-decider-flash:4b-nvfp4",
    provider: :ollama,
    dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}
  )

:ok = Omni.put_model(decision_model)

{decision, opts} = Baseline.request(:decision)
Capture.record(decision_model, decision, "#{dir}/decision.json", opts)

{decision, opts} = Baseline.request(:decision_json)
Capture.record(decision_model, decision, "#{dir}/decision_json.json", opts)
