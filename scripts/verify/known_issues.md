# Known sweep issues

Sweep failures that aren't Omni bugs, and scenarios left out on purpose. Hand-written: read it before investigating a failure, and update it after.

One entry per model and scenario. Its status says whether the matrix runs the scenario:

- **Stale catalog** (kept) - the catalog doesn't match the live API; flips once a snapshot refresh fixes the data.
- **Intermittent** (kept) - sometimes passes; each run adds evidence.
- **Open** (kept) - an Omni fix is untried or unsettled; the work is in `context/roadmap.md`.
- **Provider limit** (skipped) - right data, documented wire, fails every time.

Keeping it short:

- Rewrite an entry to say what is known now; don't append a log. The daily results record each run, and git has earlier versions.
- Fields, one line each, left out when empty: Seen, Cause, Ruled out, Revisit (what would change the status).
- Delete an entry when it passes, when its Revisit has been acted on, or when the model leaves the matrix.

## google:gemini-3.8-flash cache_usage

Provider limit, skipped. Since 2026-10-22.

- Seen: no cache hit, even with turns 60s apart.
- Cause: implicit caching only; there's no request-side control, so the dialect sends nothing for `cache:`.
- Revisit: a Gemini model reporting `cachedContentTokenCount`, which the dialect already reads.

## ollama_cloud structured_output

Provider limit. Since 2026-10-22.

- Seen: answers in prose (gemma4:31b, gpt-oss:20b); local Ollama passes the same request.
- Cause: Ollama Cloud doesn't enforce `format`.
- Revisit: the next Ollama Cloud sweep; skip `structured_output` on its entries unless it passes.

## opencode:mistral-large-4 text, no_thinking

Stale catalog, kept. Since 2026-11-16 (passed 2026-10-28).

- Seen: HTTP 400, "reasoning_effort none is not supported for this model, supported values: high, low, medium".
- Cause: models.dev lists efforts `["none", "high"]`, so `thinking: false` sends `"none"`, which Mistral has dropped.
- Revisit: a snapshot without `"none"`. `text` should then pass; drop `no_thinking` unless the data shows an off switch.

## togetherai:deepseek-ai/DeepSeek-V4-Pro-0813 no_thinking

Open, kept. Since 2026-10-28.

- Seen: reasons despite `reasoning: {enabled: false}`, sent as Together documents for a model the catalog gives a toggle.
- Revisit: try `chat_template_kwargs: {thinking: false}` (roadmap: "Together's DeepSeek V4 Pro thinks with `thinking: false`").

## zai:glm-5.3-flash cache_usage

Intermittent, kept. Since 2026-11-16 (passed 2026-10-22).

- Seen: turn 2 reads no cache; 1 hit in about 13 tries on 2026-11-16. Together's GLM-5.3-Flash cached the same day.
- Ruled out: parsing (a hit is in `prompt_tokens_details.cached_tokens`, which Omni reads), the 2s pause, `max_tokens` (unset to 8192), replayed thinking (replayed, stripped, `clear_thinking: false`).
