# Records the OpenCode Zen fixtures. Requests are real and billed.
#
#     MIX_ENV=test mix run test/support/fixtures/opencode/capture.exs
#
# Existing fixtures are skipped and replayed; delete a file to re-record it.
#
# Zen serves each model over its upstream's dialect, so the baseline is text
# once per dialect, each file prefixed with it: enough for the dialect and
# target tests. The upstreams' bytes are covered by the dialect tests.

alias Omni.Test.{Baseline, Capture}

dir = "test/support/fixtures/opencode"

# -- Baseline --

{:ok, model} = Omni.get_model(:opencode, "claude-haiku-5-5")

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/anthropic_text.sse", opts)

{:ok, model} = Omni.get_model(:opencode, "gpt-6-luna")

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/oair_text.sse", opts)

{:ok, model} = Omni.get_model(:opencode, "deepseek-v4.1-flash")

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/oaic_text.sse", opts)

{:ok, model} = Omni.get_model(:opencode, "gemini-3.8-flash")

{context, opts} = Baseline.request(:text)
Capture.record(model, context, "#{dir}/google_text.sse", opts)

# -- Cases --

# Kimi K2.5 repeats the tool call id on every argument chunk. Recorded before
# this script, from a different prompt; kept for the quirk.
{:ok, kimi} = Omni.get_model(:opencode, "kimi-k2.5")
{context, opts} = Baseline.request(:tool_use)
Capture.record(kimi, context, "#{dir}/kimi_tool_use.sse", opts)
