# Docs polish — v2.0.0

*Started 2026-11-13. The anchor for the docs polish before the v2.0.0 release: what was agreed, the phases, and where each one stands. Any session picking up a phase starts here. When the work lands, the durable rules move into `CLAUDE.md` (Documentation) and this note is deleted.*

## What the docs are for

A reader arriving at hexdocs should learn what Omni is and make a first request within a minute or two, then find depth a layer at a time:

1. **Getting started** — what Omni is, install, keys, a first request, a taste of each feature.
2. **Topic guides** — one page per area, explaining concepts and showing the common paths.
3. **Module reference** — every option, type and callback. Moduledocs stop doing guide work and link to the guides instead.

Each front door has one job. The README is the pitch on GitHub and hex.pm. Getting started is the docs main page. The `Omni` moduledoc is the reference for the top-level API. The provider table lives in one place.

## Style

Mirrors Beamlet (`../beamlet/CLAUDE.md`, Documentation and Conventions). Guidelines, not laws: break one where the page is clearly better for it.

- **First paragraph is one short sentence** in every `@moduledoc`, `@doc` and `@typedoc`. ex_doc renders it in listings. The explanation starts in the second paragraph. Exception agreed: `Omni` opens with what Omni is, not what the module is.
- **Tone**: practical, concise, example-led. Lead with what you do, not what things are. Second person, present tense. No hype.
- **British spelling** in prose. Identifiers and wire terms keep their own spelling.
- **Plain punctuation.** No em dashes in new or revised prose; use a full stop, comma, colon or brackets.
- **Markdown files soft-wrap**: one line per paragraph or list item. Doc blocks in `.ex` files hard-wrap.
- **Rely on `@spec` for types**; don't repeat them in prose. Document options where a function takes them.
- **A module is public when a user meets its name**: in a call, config, a struct they match on, or a behaviour they implement. Everything else takes `@moduledoc false` with a comment block for whoever works on it.
- **Terms**: tool use (not tool call); capability (kind of request) vs modality (kind of content); provider id, not provider module, is how users name a provider.

## Guides

In `guides/`, wired into `mix.exs` `extras`. Main page: `getting-started`. Group "Guides" holds the first four; "Upgrading to v2" and the changelog sit ungrouped.

| Page | Covers |
| --- | --- |
| Getting started | What Omni is, install, API keys, first text request, streaming, a taste of tools, structured output and decisions, where next |
| Text generation | Contexts and messages, attachments, the response, streaming events, thinking, tools, structured output, caching, options, errors |
| Decisions | Questions, answers and probabilities, state and instructions, which providers serve decision models |
| Providers and models | Selecting and configuring providers; built-in, catalog and custom; URLs and compat flags; adding models; sources; `filter` and `transform`; moving models to another dialect; `mix omni.verify` |
| Built-in providers | The table of ids, key variables and APIs, then a section per provider with only what is particular to it. The only user-facing docs for the built-ins: their modules are hidden |
| Upgrading to v2 | From `context/notes/v2-changes.md`, organised by what a v1 user has to change. Excluded from undefined-reference warnings, since it names removed functions |

Extending Omni (writing a dialect, source or provider module) is a supported but rare path. It stays in the behaviour moduledocs (`Omni.Dialect`, `Omni.Dialect.Text`, `Omni.Dialect.Decision`, `Omni.Source`, `Omni.Provider`); no guide for now.

## Module visibility and grouping

Sidebar groups, in order:

- *(ungrouped)*: `Omni`, `Omni.Model`, `Omni.Usage`, `Omni.Codec`
- **Text generation**: `Context`, `Message`, `Response`, `StreamingResponse`, `Tool`, `Tool.Runner`, `Schema`, `Schema.Adapter`
- **Content**: `Content.*`
- **Decisions**: `Decision`, `Question`, `Question.*`, `Answer`, `Answer.*`
- **Providers**: `Provider`, `Provider.Endpoint`
- **Dialects**: `Dialect`, `Dialect.Text`, `Dialect.Decision`, `Dialects.*`
- **Sources**: `Source`, `Sources.*`

Hidden: the 17 built-in provider modules (`Omni.Providers.*`), each with a comment block that keeps its wire detail and names its section of the Built-in providers guide; `Mix.Tasks.Omni.Snapshot` (a maintainer task, with no `@shortdoc` so it stays out of `mix help`); and, as before, `Application`, `Loop`, `Request`, `Parsers.*`, `Provider.Builtins`, `Provider.Loader`, `Util`, `Verify`, `Verify.Scenarios`.

## Decisions settled

- **Voice**: the guides as drafted are about right (2026-11-13).
- **Built-in providers**: hidden modules plus the guide page. Done: modules hidden, the table gone from `Omni.Provider`. Provider docs describe behaviour in plain words and send readers to `Omni.get_provider/1` for flags and URLs.
- **Tagline and package description**: "Universal Elixir client for LLM APIs. Text generation, tool use, structured output and decisions across many providers." Kept for now.
- **Guides**: all accepted after the maintainer's edits, the upgrade guide provisionally: he means to give it another pass for concision. Don't rewrite the guides' prose in the module pass; fix facts only.

## Phases

1. **Foundations** — this note. *Done.*
2. **Front door** — the guides, a slimmed README (pitch, features, install, three examples, links), a slimmed `Omni` moduledoc (a map of the API that links to the guides), `mix.exs` extras and groups. *Done 2026-11-13, bar the maintainer's own pass over the upgrade guide.*
3. **Module pass** — read every `@moduledoc`, `@doc` and `@typedoc` against the style rules, moving guide material out to the guides. One batch per session:
   - a. Core API and data: `Omni`, `Model`, `Context`, `Message`, `Response`, `StreamingResponse`, `Usage`, `Content.*`, `Tool`, `Tool.Runner`, `Schema`, `Schema.Adapter`, `Codec`. *Not started.*
   - b. Decisions: `Decision`, `Question.*`, `Answer.*`. *Not started.*
   - c. Providers: `Provider` (long moduledoc, most of it guide material, including "Migrating from v1 config"), `Endpoint`, `mix omni.verify`. The built-ins' comment blocks were converted mechanically from their moduledocs: trim any that still read as user docs (Ollama, TypeSafe). *Not started.*
   - d. Dialects and sources. *Not started.*
4. **Read-through** — build the docs, read them start to finish as a new user, check links and `mix docs` warnings, move the style rules into `CLAUDE.md`, delete this note and tick the roadmap item. *Not started.*

## Found while writing the guides

For the module pass to fix:

- **`gpt-6` is not a catalog model.** `Omni.Provider` and `Omni.Model` both show `openai: [models: [[id: "gpt-6", context_size: 1_000_000]]]` as correcting a catalog model. With no such id it would add a model with no dialect and raise. Use a real id (`gpt-6.1-sol`). `design.md` has the same example.
- **Together is now a built-in**, but `Omni.Provider`'s "Provider modules" example (`MyApp.Together`, `togetherai: [module: ...]`) and its endpoint example still treat it as a catalog provider. Use `:deepseek` or `:fireworks_ai`.
- **`:headers` is a text option too** (it is in the shared config schema) but `Omni.stream_text/3` doesn't list it; `Omni.decide/3` does.
- **`Omni.Tool` points at "the Tools section in `Omni`"**, which is gone. Point it at the Text generation guide.
- **`Omni.Provider`'s moduledoc** can lose "Built-in, catalog, and custom providers", most of "Configuration", "Endpoints" and "Compat flags" (now in Providers and models), and "Migrating from v1 config" (now in the upgrade guide). What stays: the struct, how a provider is assembled and the merge rule, provider modules and their callbacks, loading at runtime.
- **`Omni.Model`'s "Custom models"** duplicates the guide; keep the runtime `put/1` part.
- **Model ids in examples**: prefer ids that exist in the snapshot (`claude-sonnet-5-5`, `gpt-6.1-sol`, `gemini-3.5-flash`, `deepseek-v4-pro`, `typesafe/jev-1.14`).
- **`thinking: true`** is under review (roadmap, v2.0.0). The Text generation and upgrade guides document it as `:medium`; update both if it changes.
