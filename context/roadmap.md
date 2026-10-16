# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

- **Next** — work identified for the next release, grouped under the version it ships in.
- **Backlog** — work we intend to do but haven't pinned to a release.
- **Ideas** — scrappy reminders that aren't fleshed out enough to be backlog items yet.

---

## Next

### v2.0.0

Two independent breaking changes, so they ship together as one major release. Order of work: providers as data first, then the Decisions API, then additional providers on top of the new provider model.

- **Providers as data** — Replace provider modules with provider structs; dialects stay as modules. Design captured in `context/notes/providers-as-data.md` (pass one); phased outline in `context/notes/providers-as-data-plan.md`; compat research in `context/notes/compat-flags.md`. **Phase 1 landed 2026-10-16** (provider structs, loader, config by id, single-fetch sources, `filter:`, per-provider `models:`). **Phase 2 landed 2026-10-16** (compat flags, model thinking data, `handle_event/2`, dynamic thinking). Next: phase 3 (documentation).
- **Decisions API** — First non-text-generation capability: typed questions over a shared input, returning calibrated probabilities. Two wire formats (System One, OpenAI Decisions). Brainstorm in `context/notes/decisions-api.md`; a second, deeper pass is still owed before implementation. Introduces per-capability dialects on a model, which also lays the groundwork for future modalities.
- **Mistral provider** — Support Mistral directly (`api.mistral.ai`, OpenAI-compatible). Mistral is one of the catalog providers without an `api` base URL, so Omni supplies it; expected to be a built-in module with a `config/0` base URL.
- **Mistral models via OpenCode Zen** — models.dev lists OpenCode's `mistral-large-4` under `@ai-sdk/mistral`, which has no dialect mapping, so the model is skipped at load with a warning. Map it to `openai_completions` (confirm which endpoint Zen serves Mistral models on first). Expected to fall out of the providers-as-data work on mapping bespoke npm packages.
- **Dynamic thinking** — Landed in phase 2 of providers as data as `thinking: true`: the model's dynamic mode where its API has one, otherwise `:medium`.
- **Upgrade guide and changelog** — Before release, turn `context/notes/v2-changes.md` (the running log of every user-facing v2 change) into an "Upgrading to v2" extras page in the docs, and write a concise `CHANGELOG.md` entry covering the broad areas of change, pointing to the guide. Each v2 phase adds to the log as it lands.
- **Additional providers** — Two or three more providers bundled into the release once the provider refactor lands. Not yet identified; add specific entries here as they're chosen.

## Backlog

- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.

## Ideas

- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`. The per-capability dialect shape from the Decisions API work opens the door; no current need, so low priority.
