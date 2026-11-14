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
3. **Module pass** — read every `@moduledoc`, `@doc` and `@typedoc` against the style rules and the code. See [Module pass](#module-pass) for how. One batch per session, in this order:
   - Mechanical sweep: lists flush and hyphenated, code blocks fenced, separators to ` - `, the `mix.exs` function group renamed "Text generation". *Done 2026-11-13.*
   - b. Decisions, the pilot that sets the conventions: `Decision`, `Question.*`, `Answer.*`. *Done 2026-11-13.*
   - a1. Core data: `Omni`, `Model`, `Usage`, `Codec`, `Context`, `Message`, `Response`, `Content.*`. *Done 2026-11-14.*
   - a2. Streaming and tools: `StreamingResponse`, `Tool`, `Tool.Runner`, `Schema`, `Schema.Adapter`. *Done 2026-11-14.*
   - c. Providers: `Provider` (long moduledoc, much of it now in the guides, including "Migrating from v1 config"), `Endpoint`, `mix omni.verify`. *Done 2026-11-14.*
   - d. Dialects and sources. *Done 2026-11-14.*
4. **Contributor docs** — the hidden modules' comment blocks and `@doc`s, and code comments throughout `lib/`. These are docs for whoever works on the code, mostly agents. Same standard: concise and clear. Cut comments that confuse more than they clarify, restate the code, or carry stale context. Includes the built-ins' comment blocks, converted mechanically from their moduledocs: trim any that still read as user docs (Ollama, TypeSafe). Em dashes go as each comment is revised. See [Contributor docs](#contributor-docs) for how. *Batch 1 of 4 done 2026-11-14.*
5. **Read-through** — build the docs, read them start to finish as a new user, check links and `mix docs` warnings, move the style rules into `CLAUDE.md`, delete this note and tick the roadmap item. *Not started.*

## Module pass

Agreed 2026-11-13.

- **Guides and module docs have different jobs.** A guide is the first port of call: quick, easy to follow, just enough depth to get going, and often that is enough. A module's docs are the complete reference for that module: what it is, its API, every knob and lever. They are centred on the module, not the wider topic. Some overlap between the two is fine. What a moduledoc drops is guide work: topic tours, material about other modules, anything a guide says better. What it keeps or gains is anything about the module a user could need, whether or not a guide mentions it.
- **The guides are settled**: fix facts only.
- **Check facts against the code**, not only style. (`Response`'s field list was missing `:cancelled`.)
- **Lists** use `-`, flush with the surrounding text, indented only when nested. Items read `` - `:key` - text ``.
- **Code blocks are fenced**, never indented: ` ```elixir `, or the language it is (`sh`, `json`). Indented blocks parse ambiguously after lists.
- **Section order**: intro, then "Struct fields", then the sections that explain them. The overview comes first and the detail follows.
- **Naming a struct in prose**: the module name in backticks (`Omni.Content.Text`), which ex_doc links. Keep `%Text{}` for code and for showing a shape. `t:Mod.t/0` links too but renders as `Mod.t/0`, which reads badly in a sentence.
- **Validation** is described by intent, in a sentence or two. The error says the rest when someone hits it.
- **"Struct fields" sections**: every public struct has one, under that heading, even for a single field. Each is checked against the struct.
- **Guide links**: one, in the second paragraph, on modules a guide section is about (`Context`, `Message`, `StreamingResponse`, `Tool`, `Schema`, `Decision`, `Question`, `Model`, `Provider`, `Source`). Leaf modules get none.
- **`thinking: true`** is documented as the code has it (`:medium`). The roadmap item lists the docs to change if it does.
- **Each batch**: read each module beside its guide section and the code, edit, run `mix docs` and `mix precommit`, then report what was cut and where it now lives, facts corrected, and judgement calls. Update the status above. Conventions the pilot settles are added to this list.

## Contributor docs

Brief for phase 4, written 2026-11-14 at the end of phase 3. Start a fresh session from this.

- **The question for each comment**: is it true, useful and current? Check it against the code beside it. Cut one that restates the code, narrates history ("used to", "now", "v1") or explains a decision `context/design.md` already holds. Keep the why that the code can't show.
- **Style** is the module pass's: one short opening sentence on a block, British spelling, no em dashes, `-` lists flush with the text, "tool use" not "tool call", "id" not "ID".
- **Agreed 2026-11-14:**
  - **Provider blocks**: trim all 17 to what the guide doesn't say (wire field names, why a flag or hook exists, the pointer to the guide section). Config examples, tables and feature prose live in [Built-in providers](../../guides/built-in-providers.md) only. Move anything the guide lacks before cutting it.
  - **Error and warning strings**: no em dash. The remedy or expectation is a second sentence ("... invalid auth :x. Expected :bearer, ..."); a colon only where it introduces the detail and reads cleanly.
  - **`@doc` follows the function, not the module**: a public function that is part of a module's API has a `@doc`, hidden module or not. A public but internal-only function has `@doc false`, with a comment where one helps. A private function has no `@doc`, and a comment where one helps.
  - **Block placement**: `@moduledoc false` first, then the comment block.
  - **"Tool use"** in comments and section dividers. Private function names that mirror the wire (`encode_tool_call`) stay.
  - **Scope is `lib/`**. Tests change only where they match a changed string.
- **File by file**, block, `@doc`s and inline comments in one read. Four batches, one per session:
  1. `provider/loader.ex`, strings included. *Done 2026-11-14.*
  2. The 17 `Omni.Providers.*` and `Provider.Builtins`, each block checked against its guide section and its code.
  3. Other hidden modules: `Loop`, `Request`, `Parsers.*`, `Util`, `Verify`, `Verify.Scenarios`, `Application`, and both mix tasks.
  4. Inline comments in public modules: dialects and sources first, then `StreamingResponse`, `Schema`, `Codec` and the rest.
- **Known leftovers** (`grep -rc "—" lib`):
  - `request.ex` (8, with an indented comment list), `loop.ex` (6), and code comments in `sources/{llmdb,models_dev}.ex`, `dialects/{openai_responses,openai_completions,ollama_chat,google_generate_content}.ex`, `streaming_response.ex`, `schema.ex` and `parsers/*.ex`.
  - "Tool call" in comments: `providers/mistral.ex` (lines 23 to 24) and the "Tool call encoding" section comments in `dialects/ollama_chat.ex` and `dialects/openai_completions.ex`.
- **Runtime strings** changed along the way are listed in the report, since they are user-visible.
- **Each batch**: edit, run `mix docs` and `mix precommit`, report what was cut and anything found false, wait for review, commit when asked.

## Found while writing the guides

For the module pass to fix:

- **Model ids in examples**: prefer ids that exist in the snapshot (`claude-sonnet-5-5`, `gpt-6.1-sol`, `gemini-3.5-flash`, `deepseek-v4-pro`, `typesafe/jev-1.14`).
- **`thinking: true`** is under review (roadmap, v2.0.0). Document it as the code has it.
