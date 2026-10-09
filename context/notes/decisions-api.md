# Decisions API — design brainstorm (pass one)

*2026-10-09. Initial exploration of how decision models (TypeSafe System One, OpenAI Decisions) could fit inside Omni. Not a plan — a map of the design space for a second, deeper pass.*

## Background

Two takes on a new API shape appeared in September/October 2026. TypeSafe shipped first with "System One" (`POST /v1/systemone`, flagship model Jev); Ollama, llama.cpp, AWS Strands Decider and Upstage Solar Decide have since implemented the same contract. OpenAI followed with the Decisions API (`POST /v1/decisions`, model `gpt-6-luna`), which is cleaner but is the same class of capability.

The capability: send one shared input plus a set of independent, typed questions; get back calibrated probabilities instead of prose. No streaming, no tools, no multi-turn. Answers are not context for each other — each question is evaluated in isolation against the same input, so adding questions adds little latency.

This is the first non-text-generation capability Omni should support, because it will be used directly alongside text generation in the same applications (triage, routing, guardrails, confidence-gated agent steps). The task is packaging it so the two halves feel like one library, normalised the way text generation is, with the least new machinery.

Naming note: req_llm chose `ReqLLM.evaluate/4` as its verb. We prefer "decision" (OpenAI's name) and don't need to mirror req_llm.

## The two wire formats

| | System One (TypeSafe, Ollama, llama.cpp, AWS, Upstage) | OpenAI Decisions |
|---|---|---|
| Endpoint | `POST /v1/systemone` | `POST /v1/decisions` |
| Shared input | `state`: string, JSON object or array. Ollama adds a base64 `images` list | `input`: string, or user messages with `input_text` / `input_image` parts. No JSON objects |
| Questions | map keyed by caller-chosen name | array, optional `name`, answers returned in question order |
| Yes/no | `noul`, optional `criteria: {true, false}` descriptions. Answer: `noul` 0..1 | `predicate`. Answer: `probability` |
| Pick one | `choice`, `criteria` map of option → description (or null). Answer: `choice`, `probabilities` map, `confidence` | `choice`, `choices` list of `{value, description}`; value may be string or boolean. Answer: `choice`, `probabilities` list, `confidence` |
| Scale | `score`, `criteria` ordered list of descriptions. Answer: float index (can fall between levels), `legend`, `probabilities`, `confidence` | `score`, `levels` list of `{label, description}`. Answer: float index, `probabilities` with label/value, `confidence` |
| Refusal | none | per-answer `type: "refusal"`; other answers still returned |
| Extras | none | `safety_identifier` |
| Usage | `input_tokens`, `output_tokens` | input, output, cached, cache-write, reasoning tokens |
| Limits | TypeSafe: score 2–10 levels; Ollama: 2–26 levels, 1–64 questions, 64 KiB body; choice 2–255 options | 2–255 choices; up to 128 images; images must be base64 data URLs or public HTTP(S) |
| Streaming | no | no (undocumented) |

Confidence is computed differently everywhere. TypeSafe: `(p_max − 1/n) / (1 − 1/n)` for choice, a distance-weighted variant for score. Ollama: `1 − H(p) / ln(N)` (entropy). OpenAI: unspecified. Noul/predicate answers carry no confidence anywhere. This matters if callers threshold on confidence across providers — probabilities are the real contract.

The System One shape is now a de facto open standard with five implementations, so one dialect gives broad coverage. OpenAI is the lone second dialect.

## Catalog reality check (models.dev, live, 2026-10-09)

- **models.dev flags these models** with `type: "decision"`, but the default `api.json` omits specialised types. Both `mix omni.snapshot` and `ModelsDev` live mode fetch the default URL, so the bundled snapshot contains zero decision models. `?type=all` (or `?type=decision`) fixes that.
- **The eligibility filter would drop them anyway.** Every decision model has `tool_call: false`; `eligible?/1` in `Omni.Sources.ModelsDev` requires tool use. Needs to become type-aware.
- **Dialect inference is wrong for them.** npm metadata maps them to `openai_completions`. Decision models need their own rule: `type: decision` ⇒ systemone unless the provider says otherwise.
- **`type` is exclusive, which mismatches OpenAI.** `gpt-6-luna` under `openai` is a normal chat model with no decision marker. Vercel's gateway lists a separate synthetic id, `openai/gpt-6-luna-decisions`. The catalog cannot express "one id serves both the Responses API and the Decisions API". OpenAI support needs provider-level stamping, or an upstream schema change.
- **TypeSafe itself is not in models.dev**, and local Ollama never is. Both need bespoke model lists.
- **Of Omni's built-ins, only OpenCode** has decision models today: `jev-1.13`, `jev-1.13-free` (npm `@ai-sdk/openai-compatible`). Which path Zen exposes them on is unverified. Other hosts in the catalog (Vercel, Cloudflare Workers AI/AI Gateway, nano-gpt, vivgrid) aren't built-ins.
- Decision models in the catalog (13 total): Jev variants, Liquid D1, Cloudflare Clef / Clef Flash (multimodal, text + image), Laya, and Vercel's `openai/gpt-6-luna-decisions`.
- **LLMDB:** req_llm's Decisions PR says llm_db 2026.10.0 carries "evaluation capability and execution metadata". Not yet checked what fields; the LLMDB source should read capability rather than guess.

## Design shapes

### Surface API

This is a different verb, not an option on `generate_text`. The model evaluates rather than generates, so `generate_decision` reads wrong. Proposed: `Omni.decide/4`, mirroring OpenAI's resource name:

```elixir
{:ok, decision} =
  Omni.decide({:openai, "gpt-6-luna"}, ticket_text,
    department: Omni.choice("Which team should handle this?",
      billing: "Payments and refunds",
      technical: "Bugs and integrations",
      other: nil
    ),
    urgent: Omni.predicate("The message conveys time pressure"),
    frustration: Omni.score("How frustrated is the customer?",
      ["Calm", "Frustrated but civil", "Very angry"]
    )
  )

decision.answers.department
#=> %Omni.Answer.Choice{choice: :technical, probabilities: %{technical: 0.97, ...}, confidence: 0.96}
decision.answers.urgent
#=> %Omni.Answer.Predicate{probability: 0.81}
decision.usage
#=> %Omni.Usage{input_tokens: 174, total_cost: ...}
```

Shape decisions baked into the sketch:

- **Questions are a keyword list.** Names are required in Omni even though OpenAI makes them optional. A keyword list gives ordering for OpenAI's positional answers and keys for System One's map; answers come back as a map keyed by the same atoms.
- **Separate structs per question and answer type**, following the Content convention (match on struct name, not a type field): `Omni.Question.{Predicate, Choice, Score}` and `Omni.Answer.{Predicate, Choice, Score, Refusal}`. Refusal exists only for OpenAI but belongs in the normalised type.
- **The yes/no primitive is called `predicate`** (OpenAI's name). "Noul" is TypeSafe jargon; req_llm's "boolean" wrongly suggests a boolean answer.
- **Choice options and score levels accept short and long forms**: a bare list of names, or name → description pairs. Omni sends strings and maps answers back to the caller's key type (same trick as `Omni.Schema` key normalisation).
- **State accepts a string, a JSON-encodable term, or content blocks.** Maps/lists go native to System One and get JSON-encoded for OpenAI. A list of `Text` and `Attachment` blocks covers images, reusing the existing modality check against `model.input_modalities`. Accepting a `%Context{}` as state (serialised to a chat log) would be a cheap, genuinely useful bridge between the two halves of the library — "judge this conversation" is a headline use case.
- **Result is a new `%Omni.Decision{}`**: `model`, `answers`, `usage`, `raw`. Stretching `%Response{}` would be dishonest — its enforced keys and message fields mean nothing here. Text and decisions share `Usage` and `Model`, not the envelope.
- **No streaming variant.** None of the APIs stream; a fake single-event stream adds nothing. `decide/4` is synchronous.
- **Convenience constructors** `Omni.predicate/2`, `Omni.choice/3`, `Omni.score/3` sit alongside `Omni.tool/1` and `Omni.message/1`.

Deliberately not normalised in pass one: confidence. Pass through the provider's number and document that the formula varies. Computing Omni's own confidence from probabilities is an option for pass two.

### Models and capability

The `%Model{}` needs to say what it can do; today its single `dialect` field says it implicitly. Two shapes:

- **A. Additive field.** Keep `dialect` for text generation and add `decision_dialect`, both nillable. Jev is `dialect: nil, decision_dialect: SystemOne`; GPT-6 Luna has both. `Model.supports?(model, :decision)` reads the field. Non-breaking; the "dialect never nil" source invariant loosens to "at least one dialect".
- **B. Capability-keyed map.** `dialects: %{text: Mod, decision: Mod}` with `Model.dialect(model, :text)`. Cleaner and generalises; breaks every `model.dialect` access.

**Open choice for pass two.** A v2.0.0 is already in the works for other reasons, so B's breaking cost isn't a deciding factor. Choose on clarity, not compatibility. A is B in disguise either way.

Catalog work that follows regardless of A/B: snapshot with `?type=all`; type-aware eligibility; decision dialect inference; provider overrides where the catalog is silent. Specifically:

- `Omni.Providers.OpenAI` stamps the decision dialect onto Luna models in `models/0`.
- New `Omni.Providers.TypeSafe` with a bespoke model list (no catalog entry).
- Local Ollama's config-driven list grows a `type: :decision` sugar so users can declare `nimble` / `tev1` without naming dialect modules.
- `generate_text` on a decision-only model returns `{:error, {:unsupported_operation, :text}}` before any HTTP; `decide` likewise for chat-only models.

### Dialects

The existing `Omni.Dialect` behaviour cannot absorb this. Its callbacks take a `%Context{}` and parse streaming events; decisions take state plus questions and parse one JSON document. One behaviour would mean callbacks half the implementers ignore.

So: per-capability dialect *behaviours*, not parallel dialect hierarchies. A dialect is still "a wire format"; the decision formats are orthogonal to the chat formats (Jev speaks System One regardless of whether its host's chat dialect is Ollama or OpenAI Completions).

```elixir
defmodule Omni.Dialect.Decision do
  @callback option_schema() :: Peri.map_schema()
  @callback handle_path(Model.t(), map()) :: String.t()
  @callback handle_body(Model.t(), state :: term(), [Question.t()], map()) :: map()
  @callback handle_response(map(), [Question.t()]) ::
              {:ok, %{answers: map(), usage: map()}} | {:error, term()}
end

Omni.Dialects.SystemOne          # registry id "systemone"
Omni.Dialects.OpenAIDecisions    # registry id "openai_decisions"
```

Passing the questions into `handle_response/2` lets the dialect map string keys and option values back to the caller's atoms. The registry in `Omni.Dialect` grows two string ids. Renaming the text behaviour to `Omni.Dialect.Text` is a cosmetic v2 question.

Providers need almost nothing: `build_url/2` and `authenticate/2` are reused unchanged (OpenCode's path-based auth already copes with a new path). `modify_body/3` is typed on `%Context{}`; leave decision hooks out until a provider quirk demands them.

### Pipeline reuse

Request side is mostly shareable; response side is not.

| Piece | Reusable? | Note |
|---|---|---|
| `Request.validate/2` | Yes, with a split | Separate config keys (`api_key`, `base_url`, `headers`, `plug`, `timeout`, `metadata`) from text inference keys so each operation merges its own schema |
| `Request.build/3` | Partly | URL, auth, headers, plug, timeout shared. Extract a `new_req` helper. Decisions don't use `into: :self` |
| `check_status`, error body reading | Yes | Move to shared helpers |
| `Request.stream/3`, parsers | No | Sibling `Request.send/3`: request, status check, JSON decode |
| `StreamingResponse`, `Loop` | No | Nothing to stream or loop |
| `Usage` | Yes | Private cost computation in `StreamingResponse` becomes `Usage.from_counts/2` (or similar) so both paths share it |
| `Response` | No | New `%Decision{}` |
| Modality check | Yes | Lift `check_modality` out of `validate_context` |
| Test layers, fixtures, `Capture` | Yes | Same `Req.Test` stub pattern; add a JSON fixture flavour and a non-streaming capture mode |

### Sketch of the module layout

```
lib/omni.ex                          # + decide/4, predicate/2, choice/3, score/3
lib/omni/decision.ex                 # %Decision{} result: model, answers, usage, raw
lib/omni/question.ex                 # constructors + Peri schema for question validation
lib/omni/question/{predicate,choice,score}.ex
lib/omni/answer/{predicate,choice,score,refusal}.ex
lib/omni/dialect/decision.ex         # behaviour
lib/omni/dialects/system_one.ex
lib/omni/dialects/openai_decisions.ex
lib/omni/providers/typesafe.ex       # new provider, bespoke models/0
lib/omni/request.ex                  # split: shared build/validate + text stream + decision send
lib/omni/model.ex                    # capability/dialect change (A or B)
lib/omni/sources/models_dev.ex       # type-aware eligibility + decision dialect inference
lib/omni/sources/llmdb.ex            # read evaluation capability metadata
lib/mix/tasks/omni.snapshot.ex       # ?type=all
```

Net new: two dialect modules, question/answer structs with a Peri schema, the `Decision` struct, a sync send path, one provider, source and snapshot changes, the model change. Moved: validation split, cost computation, status helpers. Nothing in the text pipeline changes behaviour.

## Open questions for pass two

- **Model struct shape** — A (additive field) vs B (capability-keyed dialect map). Decide on clarity; v2 is already coming.
- **OpenCode Zen's path and auth for Jev.** Needs a live probe before it can be a working built-in.
- **Confidence normalisation.** Pass-through vs Omni-computed from probabilities.
- **Non-string instructions.** TypeSafe allows JSON objects/arrays as instructions; OpenAI requires strings. Probably accept any term and JSON-encode for OpenAI.
- **Silently dropped fields.** Predicate criteria on OpenAI, option descriptions on some hosts. Makes the parked warning mechanism in `roadmap.md` more pressing.
- **Limits.** Score levels 2–10 (TypeSafe), 2–26 (Ollama), unspecified (OpenAI). Validate the shared floor and let providers reject the rest.
- **Upstream contribution.** models.dev's exclusive `type` can't express GPT-6 Luna. Worth an issue — otherwise every client hard-codes the OpenAI exception.
- **llm_db's evaluation metadata.** Check the fields so the LLMDB source can read capability instead of guessing.
- **`%Context{}` as state.** Confirm the serialisation shape (TypeSafe docs explicitly suggest chat logs as structured state).

## Sources

- TypeSafe: [System One](https://docs.typesafe.ai/concepts/system-one.md), [API reference](https://docs.typesafe.ai/api.md), [primitives](https://docs.typesafe.ai/primitives.md), [confidence](https://docs.typesafe.ai/confidence.md), [docs index](https://docs.typesafe.ai/llms.txt)
- OpenAI: [Decisions guide](https://developers.openai.com/api/docs/guides/decisions), [Decisions create reference](https://developers.openai.com/api/reference/resources/decisions/methods/create/index.md)
- Ollama: [systemone API reference](https://docs.ollama.com/api/systemone)
- models.dev: [README (`type` filter)](https://github.com/anomalyco/models.dev), `https://models.dev/api.json?type=decision`
- req_llm: [evaluate docs](https://req-llm.hexdocs.pm/ReqLLM.html), [Decisions PR #1075](https://github.com/agentjido/req_llm/pull/1075)
