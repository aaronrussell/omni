# Omni Roadmap

**Last updated:** April 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI, Alibaba/DashScope. Each is a small module once the infrastructure exists. See `## Provider notes` below for known quirks.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.
- **Dynamic thinking as a first-class level** — providers are trending toward adaptive/dynamic reasoning (Anthropic adaptive, Gemini `thinkingBudget: -1`). Worth considering a dedicated `:dynamic` / `:auto` level alongside the current `:low`–`:max` scale so callers can say "let the model decide" without overloading `:max`.

## Provider notes

Context for future provider additions — what's unusual, what existing dialect fits, what needs custom handling.

### Alibaba / DashScope (Qwen)

- **Chat completions: OpenAI-compatible.** Drop-in replacement at `https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions` (plus regional variants: dashscope-us, dashscope.aliyuncs.com, cn-hongkong). Same `Authorization: Bearer` auth, same SSE streaming, standard body fields.
- **Thinking is the only real divergence.** Qwen doesn't use `reasoning_effort`. Instead, the body takes two extension fields:
  ```json
  { "enable_thinking": true, "thinking_budget": 50 }
  ```
  Response thinking arrives in `reasoning_content` deltas — which our `openai_completions` dialect already handles.
- **Current catalog mapping** (`lib/mix/tasks/models.get.ex`): `@ai-sdk/alibaba → openai_completions`. This is correct for gateway use (OpenCode, OpenRouter) where the gateway handles any upstream translation itself.
- **For a dedicated `Omni.Providers.Alibaba`** pointing directly at DashScope: use the `openai_completions` dialect, override `modify_body/3` to translate `reasoning_effort` → `enable_thinking` + `thinking_budget`, and (optionally) handle ephemeral cache-control extensions. No new dialect needed.
- **Out of scope of Omni** (noted because `@ai-sdk/alibaba` handles them): video generation uses the native DashScope endpoint (not OpenAI-compat); vendor-specific prompt caching extensions.
- **Thinking-capable models:** qwen3-max, qwen3.5-plus, qwen3.5-flash, qwen3.6-plus, qwen-plus, qwen-flash, qwen-turbo (hybrid, controllable via `enable_thinking`). qwq-plus / qwq-32b are thinking-only (cannot disable).

### OpenCode (multi-dialect gateway)

- Multi-dialect: the JSON `dialect` field per-model is required. Models where `@npm_to_dialect` can't resolve the dialect end up with `"dialect": null` and break loading (`Omni.Dialect.get!(nil)` raises). When new provider NPM ids appear in models.dev, add them to `@npm_to_dialect` rather than letting nulls land in the catalog.

- **`Omni.Codec`** — Lossless encode/decode for Omni structs to plain maps (for JSON/JSONB storage). Was specified in detail in the removed `context/sessions.md`. Not tied to any agent storage — standalone utility for applications that persist conversations. Can be re-derived from struct definitions when needed.
