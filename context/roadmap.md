# Roadmap

Work tracking for `omni`. This is a live document — add to it freely, clean it up as items land or get rethought.

---

## Scheduled

*(empty)*

## Parked ideas

- **Additional providers** — Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_modalities[:input]`.
- **Warning mechanism** — Some providers silently drop unsupported features (e.g. Ollama skips URL-based image attachments). Need a consistent way to surface these gaps to users — options include Logger warnings, a warnings list on Response, or warning events in the stream.
- **Dynamic thinking as a first-class level** — providers are trending toward adaptive/dynamic reasoning (Anthropic adaptive, Gemini `thinkingBudget: -1`). Worth considering a dedicated `:dynamic` / `:auto` level alongside the current `:low`–`:max` scale so callers can say "let the model decide" without overloading `:max`.
- **Model loading patterns** — Research flexible approaches to model loading beyond the current all-or-nothing per-provider pattern. Areas to explore: (1) filtered loading — letting users load a subset of a provider's models based on predicates like cost thresholds, modality support, or context size; (2) external model sources — loading model definitions from packages like `llm_db` or other registries, converting to `%Model{}` structs, and registering them with Omni; (3) whether `models/0` should accept filter options or whether filtering belongs at a higher level (e.g. a query API over the already-loaded `:persistent_term` data). Consider the interaction with the provider loading change above — if all built-ins load by default, filtering becomes more useful.
