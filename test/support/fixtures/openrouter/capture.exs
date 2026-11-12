# Records the OpenRouter fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/openrouter/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/openrouter"
{:ok, model} = Omni.get_model(:openrouter, "deepseek/deepseek-v4.1-flash")

# -- Baseline --

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/text.sse", opts)

{context, opts} = Baseline.request(:thinking)
Capture.record(model, context, "#{dir}/thinking.sse", opts)

{context, opts} = Baseline.request(:tool_use)
Capture.record(model, context, "#{dir}/tool_use.sse", opts)

{:ok, jev} = Omni.get_model(:openrouter, "typesafe/jev-1.14")

{decision, opts} = Baseline.request(:decision)
Capture.record(jev, decision, "#{dir}/decision.json", opts)

{decision, opts} = Baseline.request(:decision_json)
Capture.record(jev, decision, "#{dir}/decision_json.json", opts)

# -- Cases --

# Each upstream's reasoning comes back in its own `reasoning_details` shape,
# replayed verbatim on the next turn.
{:ok, gemini} = Omni.get_model(:openrouter, "google/gemini-3.8-flash")
{:ok, haiku} = Omni.get_model(:openrouter, "anthropic/claude-haiku-5.5")

# Gemini: encrypted reasoning only, no reasoning text.
{context, opts} = Baseline.request(:thinking)
Capture.record(gemini, context, "#{dir}/gemini_thinking.sse", opts)

# Gemini with parallel tool calls: one `reasoning.encrypted` entry carries the
# first call's id, and the second step sends it back with the tool results.
{context, opts} = Baseline.request(:kitchen_sink)

with {:ok, resp} <- Capture.record(gemini, context, "#{dir}/gemini_tools_1.sse", opts) do
  Capture.record(gemini, Baseline.tool_round(context, resp), "#{dir}/gemini_tools_2.sse", opts)
end

# Anthropic: reasoning text with a signature.
{context, opts} = Baseline.request(:thinking)
Capture.record(haiku, context, "#{dir}/anthropic_thinking.sse", opts)

# Anthropic cache: Claude caches only on request, so top-level `cache_control`
# goes with `cache: :short`. Turn 1 writes the prefix, turn 2 reads it. Run
# with a cold cache (no Haiku cache run in the last 5 minutes), or turn 1
# reads instead of writing.
{context, opts} = Baseline.request(:cache_usage)

with {:ok, resp} <- Capture.record(haiku, context, "#{dir}/anthropic_cache_1.sse", opts) do
  Process.sleep(2_000)
  turn2 = Baseline.follow_up(:cache_usage, context, resp)
  Capture.record(haiku, turn2, "#{dir}/anthropic_cache_2.sse", opts)
end
