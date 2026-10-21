# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

- **Next** — work identified for the next release, grouped under the version it ships in.
- **Backlog** — work we intend to do but haven't pinned to a release.
- **Ideas** — scrappy reminders that aren't fleshed out enough to be backlog items yet.

---

## Next

### v2.0.0

Two independent breaking changes, so they ship together as one major release. Order of work: providers as data first, then the Decisions API, then additional providers on top of the new provider model.

- **Providers as data** — Replace provider modules with provider structs; dialects stay as modules. The design as built is in `context/design.md` (Providers, Dialects → Compat flags, Thinking). The working notes (`context/notes/providers-as-data*.md`, `compat-flags.md`) are kept until phase 4 is done, then deleted; everything durable in them is in `design.md` or below. **Phase 1 landed 2026-10-16** (provider structs, loader, config by id, single-fetch sources, `filter:`, per-provider `models:`). **Phase 2 landed 2026-10-16** (compat flags, model thinking data, `handle_event/2`, dynamic thinking). **Phase 3 landed 2026-10-21** (docs: provider moduledocs, tiers, `design.md`). Next: phase 4, providers on the new model:
  - **Verification procedure** — live test, fixture capture, built-in module, moduledoc. The contribution path for moving a provider into the verified tier. Mistral is the first to go through it (below).
  - **Bespoke npm mapping** — `@ai-sdk/mistral`, `@ai-sdk/xai`, `@ai-sdk/togetherai` and similar packages that are OpenAI-compatible in practice, added to both sources' npm-to-dialect tables. Resolves Mistral via OpenCode Zen.
  - **Version-segment fixes** — ten catalog base URLs lack a version segment (`https://api.deepseek.com`, `https://api.novita.ai/openai`, …); fix each in its module's `config/0` as the provider is verified.
  - **Multi-mount models** — gateway models served from a different base URL than their provider are skipped at load by both sources. Support them, or keep skipping deliberately.
  - **Flexible routing** — `Model.put_dialect/3`, so a gateway that serves one model over several dialects (OpenRouter: Completions, Responses, Messages) can route a model to another dialect in its provider's list. Also the fix for OpenRouter's `anthropic/*` cache-control shape.
  - **Bad catalog URLs** — whether a catalog-tier provider that fails with an obviously wrong URL deserves a better error than a 404. Connects to the warning mechanism.
  - **Which providers to verify, and in what order.**
- **Decisions API** — First non-text-generation capability: typed questions over a shared input, returning calibrated probabilities. Two wire formats (System One, OpenAI Decisions). Brainstorm in `context/notes/decisions-api.md`; a second, deeper pass is still owed before implementation. Introduces per-capability dialects on a model, which also lays the groundwork for future modalities.
- **Mistral provider** — Support Mistral directly (`api.mistral.ai`, OpenAI-compatible). Mistral is one of the catalog providers without an `api` base URL, so Omni supplies it; expected to be a built-in module with a `config/0` base URL.
- **Mistral models via OpenCode Zen** — models.dev lists OpenCode's `mistral-large-4` under `@ai-sdk/mistral`, which has no dialect mapping, so the model is skipped at load with a warning. Map it to `openai_completions` (confirm which endpoint Zen serves Mistral models on first). Expected to fall out of the providers-as-data work on mapping bespoke npm packages.
- **Dynamic thinking** — Landed in phase 2 of providers as data as `thinking: true`: the model's dynamic mode where its API has one, otherwise `:medium`.
- **Upgrade guide and changelog** — Before release, turn `context/notes/v2-changes.md` (the running log of every user-facing v2 change) into an "Upgrading to v2" extras page in the docs, and write a concise `CHANGELOG.md` entry covering the broad areas of change, pointing to the guide. Each v2 phase adds to the log as it lands.
- **Additional providers** — Two or three more providers bundled into the release once the provider refactor lands. Not yet identified; add specific entries here as they're chosen.

## Backlog

- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream. Compat `omit` gives it the message for free ("this provider ignores `:cache`"), as does `thinking: false` on a model that can't switch off.
- **Candidate compat flags** — Seen in prior art (Pi, Vercel, LiteLLM, req_llm); each ships only with a verified provider that needs it (the ship rule in `design.md`).
  - Anthropic Messages (Fireworks' and OpenRouter's Anthropic endpoints, MiniMax): empty thinking signatures allowed; no `cache_control` on tools; no eager tool-input streaming; temperature unsupported; adaptive thinking forced.
  - OpenAI Responses (xAI, OpenRouter): no long cache retention; no developer role; `store: true` rejected.
  - Completions: a forced-tool `output_format` (Groq, Fireworks, req_llm's default); `thinking_replay_field: "reasoning_content"` (DeepSeek V4; Moonshot's suspected need didn't reproduce); Together's variants.
  - A stateful parse hook for reasoning streamed inline as `<think>` tags (req_llm does this for Groq).
- **Unverified live** — Built-in behaviour not yet run against the live API, for lack of account access:
  - NearAI entirely (no key; wire output unchanged since phase 1).
  - Groq Qwen: the `"default"` effort and `reasoning_format: "parsed"` (paid plans closed to sign-ups).
  - Ollama Cloud string levels on models other than gpt-oss (`glm-5.3`, `kimi-k3`; paid plan). `glm-5.2` reports an off switch the catalog lacks, so off sends nothing there. `deepseek-v4-flash`, `minimax-m3` and `mistral-large-4` report no thinking values at all.
  - Alibaba's budget-only thinking shape (`qwen3-next-80b-a3b-thinking` isn't served on the international endpoint).
  - Accepted as imperfect: Opus 4.5 and 4.6 use budget thinking rather than adaptive since the prefix lists went.

## Ideas

- **OpenRouter models API as a data source** — `https://openrouter.ai/api/v1/models` carries per-model reasoning data (`supported_efforts`, `mandatory`, `default_effort`) and per-endpoint `supported_parameters`, which llm_db drops. Could feed `Model.thinking` for OpenRouter more precisely than models.dev.
- **Align source filtering** — ModelsDev drops deprecated models; LLMDB keeps deprecated and drops retired. Pick one rule.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`. The per-capability dialect shape from the Decisions API work opens the door; no current need, so low priority.
