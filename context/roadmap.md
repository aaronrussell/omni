# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

---

## Scheduled

- **Prompt-cache usage on the OpenAI Completions dialect** — `normalize_usage/1` in `lib/omni/dialects/openai_completions.ex` only extracts `prompt_tokens` / `completion_tokens` and ignores `prompt_tokens_details.cached_tokens` and `prompt_tokens_details.cache_creation_input_tokens`. As a result, `cache_read_tokens` / `cache_write_tokens` on `%Usage{}` are always `0` for every OAI-Completions provider that supports caching (Groq, Moonshot, OpenRouter, OpenCode, Z.ai, Venice). Fix is to map these into the `cache_read_input_tokens` / `cache_creation_input_tokens` raw keys that `StreamingResponse.build_usage/2` already consumes — one dialect change, broad benefit.
- **Load all built-in providers by default** — `@default_providers` in `Omni.Application` currently only loads `[:anthropic, :google, :openai]`, requiring users to configure `:providers` to access the other 8 built-in providers. Change to `Map.keys(@builtin_providers)` so all built-ins are available out of the box. The cost is negligible (a few hundred models deserialized from JSON into `:persistent_term`). Users who want to restrict the set can still use `config :omni, :providers, [:anthropic]`. The `:providers` config key becomes a filter rather than an additive list — document accordingly.

---

## Parked ideas

- **Additional providers** — Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.
- **Dynamic thinking as a first-class level** — providers are trending toward adaptive/dynamic reasoning (Anthropic adaptive, Gemini `thinkingBudget: -1`). Worth considering a dedicated `:dynamic` / `:auto` level alongside the current `:low`–`:max` scale so callers can say "let the model decide" without overloading `:max`.
- **Model loading patterns** — Research flexible approaches to model loading beyond the current all-or-nothing per-provider pattern. Areas to explore: (1) filtered loading — letting users load a subset of a provider's models based on predicates like cost thresholds, modality support, or context size; (2) external model sources — loading model definitions from packages like `llm_db` or other registries, converting to `%Model{}` structs, and registering them with Omni; (3) whether `models/0` should accept filter options or whether filtering belongs at a higher level (e.g. a query API over the already-loaded `:persistent_term` data). Consider the interaction with the provider loading change above — if all built-ins load by default, filtering becomes more useful.
