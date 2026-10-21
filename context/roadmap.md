# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

- **Next** — work identified for the next release, grouped under the version it ships in.
- **Backlog** — work we intend to do but haven't pinned to a release.
- **Ideas** — scrappy reminders that aren't fleshed out enough to be backlog items yet.

---

## Next

### v2.0.0

Two independent breaking changes, so they ship together as one major release. Order of work: providers as data first, then the Decisions API, then additional providers on top of the new provider model.

- **Providers as data** — Replace provider modules with provider structs; dialects stay as modules. The design as built is in `context/design.md` (Providers, Dialects → Compat flags, Thinking). **Phase 1 landed 2026-10-16** (provider structs, loader, config by id, single-fetch sources, `filter:`, per-provider `models:`). **Phase 2 landed 2026-10-16** (compat flags, model thinking data, `handle_event/2`, dynamic thinking). **Phase 3 landed 2026-10-21** (docs: provider moduledocs, tiers, `design.md`). **Phase 4 closed 2026-10-21**: the remaining work became the verification and provider items below and two backlog items; the working notes were retired.
- **Verification** — Tooling and a procedure for verifying providers and models against live APIs: `mix omni.capture` for fixtures, a shipped `mix omni.verify`, a sweep script over a maintained list of common models, live tests retired, and a rethink of the integration tests. Also the documented contribution path into the verified tier. Needs its own design session; where we got to is in `context/notes/verification.md`. The providers below would be its first users.
- **Decisions API** — First non-text-generation capability: typed questions over a shared input, returning calibrated probabilities. Two wire formats (System One, OpenAI Decisions). Brainstorm in `context/notes/decisions-api.md`; a second, deeper pass is still owed before implementation. Introduces per-capability dialects on a model, which also lays the groundwork for future modalities.
- **xAI provider** — Built-in module. The catalog has no base URL for xAI, so `config/0` supplies one (`https://api.x.ai/v1`), and `@ai-sdk/xai` maps to a dialect in both sources' npm tables. xAI serves Chat Completions and Responses; choose at verification.
- **Mistral provider** — Built-in module (`https://api.mistral.ai/v1`, OpenAI-compatible); the catalog has no base URL for it either. Mapping `@ai-sdk/mistral` to `openai_completions` also loads OpenCode Zen's Mistral models (`mistral-large-4`), which are skipped today: confirm which endpoint Zen serves them on first.
- **Together provider** — Built-in module; no catalog base URL (`https://api.together.xyz/v1`). Maps `@ai-sdk/togetherai`. The backlog's candidate flags list "Together's variants" to check.
- **Dynamic thinking** — Landed in phase 2 of providers as data as `thinking: true`: the model's dynamic mode where its API has one, otherwise `:medium`.
- **Upgrade guide and changelog** — Before release, turn `context/notes/v2-changes.md` (the running log of every user-facing v2 change) into an "Upgrading to v2" extras page in the docs, and write a concise `CHANGELOG.md` entry covering the broad areas of change, pointing to the guide. Each v2 phase adds to the log as it lands.

## Backlog

- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream. Compat `omit` gives it the message for free ("this provider ignores `:cache`"), as does `thinking: false` on a model that can't switch off.
- **Per-model base URLs** — Some gateways serve part of their lineup from a different base URL than the provider's: ofox serves Claude models at `/anthropic/v1` and Gemini at `/gemini/v1beta` beside its Completions root; also zenmux, neon, freemodel, and Azure, Bedrock and Vertex with templated URLs. Both sources skip these models with a warning. Open question: a `base_url` on the model that overrides the provider's, or provider modules rewriting the request URL case by case. Additive, so not needed for v2.0.
- **Dialect switching** — `Model.put_dialect/3`, so a model can be sent over another dialect in its provider's list (OpenRouter serves one model over Completions, Responses or Messages). Also the fix for OpenRouter's `anthropic/*` cache-control shape. Additive, so not needed for v2.0.
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
