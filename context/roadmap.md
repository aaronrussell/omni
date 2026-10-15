# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

- **Next** — work identified for the next release, grouped under the version it ships in.
- **Backlog** — work we intend to do but haven't pinned to a release.
- **Ideas** — scrappy reminders that aren't fleshed out enough to be backlog items yet.

---

## Next

### v2.0.0

Two independent breaking changes, so they ship together as one major release. Order of work: providers as data first, then the Decisions API, then additional providers on top of the new provider model.

- **Providers as data** — Replace provider modules with provider structs; dialects stay as modules. Design captured in `context/notes/providers-as-data.md` (pass one); phased outline in `context/notes/providers-as-data-plan.md`. Includes `filter:` — a predicate over loaded `%Model{}` structs — which resolves the old "model loading patterns" question (filtered loading by cost, modality, context size, etc.) and the per-provider `models:` key for additive custom models. Several points are deferred to later passes (see the note's "Deferred" section).
- **Decisions API** — First non-text-generation capability: typed questions over a shared input, returning calibrated probabilities. Two wire formats (System One, OpenAI Decisions). Brainstorm in `context/notes/decisions-api.md`; a second, deeper pass is still owed before implementation. Introduces per-capability dialects on a model, which also lays the groundwork for future modalities.
- **Mistral provider** — Support Mistral directly (`api.mistral.ai`, OpenAI-compatible). Mistral is one of the catalog providers without an `api` base URL, so Omni supplies it; expected to be a table entry once providers are data.
- **Mistral models via OpenCode Zen** — models.dev lists OpenCode's `mistral-large-4` under `@ai-sdk/mistral`, which has no dialect mapping, so the model is skipped at load with a warning. Map it to `openai_completions` (confirm which endpoint Zen serves Mistral models on first). Expected to fall out of the providers-as-data work on mapping bespoke npm packages.
- **Additional providers** — Two or three more providers bundled into the release once the provider refactor lands. Not yet identified; add specific entries here as they're chosen.

## Backlog

- **Dynamic thinking as a first-class level** — Providers are trending toward adaptive/dynamic reasoning (Anthropic adaptive, Gemini `thinkingBudget: -1`). Add a dedicated `:dynamic` / `:auto` level alongside the current `:low`–`:max` scale so callers can say "let the model decide" without overloading `:max`. Candidate for v2.0.0.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.

## Ideas

- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`. The per-capability dialect shape from the Decisions API work opens the door; no current need, so low priority.
