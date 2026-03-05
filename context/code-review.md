# Code Review — Pre-launch

Full review of all 38 modules across 8 subsystems. Findings are categorized by severity within each subsystem. Cross-cutting issues are called out at the top.

**Processing:** Work through items top-down. Each item gets a status marker as it's addressed:
- `[FIXED]` — resolved with a code change
- `[WONTFIX]` — reviewed, intentionally leaving as-is (reason noted)
- `[DEFERRED]` — real issue but not pre-launch priority
- No marker — still to review

---

## Cross-cutting Issues

These affect multiple modules or span subsystem boundaries:

1. `[FIXED]` **Usage cost computation is wrong** — `streaming_response.ex:498-501` computes costs as `tokens * cost_per_million` without dividing by 1,000,000. Model cost fields are documented as "per million tokens" (confirmed in JSON data files). All `Usage` cost fields were inflated by 1M×. Fixed: added `/ 1_000_000` to all four cost computations and corrected the test.

2. `[FIXED]` **`normalize_thinking/1` duplicated across all 5 dialects** — Eliminated entirely. Each dialect's `maybe_put_thinking` now pattern-matches directly on atom levels and map opts, removing the intermediate tuple normalization.

3. `[FIXED]` **`maybe_put/3` duplicated across all dialects** — Extracted to `Omni.Util.maybe_put/3` and `maybe_merge/2` (works on both maps and keyword lists). All 5 dialects, `streaming_response.ex`, and `request.ex` now import from `Omni.Util`. Dialect `maybe_put_*` wrappers converted to `encode_*` pure functions where possible; body-transforming cases (Anthropic thinking/output) renamed to `apply_*` for clarity.

4. `[WONTFIX]` **`Enumerable.t()` specs on `new/1` constructors are inconsistent** — False positive. Both `Map.new/1` and `struct!/2` accept any enumerable via `Enum.reduce`. The spec `Enumerable.t()` is accurate for all constructors regardless of which internal path they use.

5. `[FIXED]` **`thinking: true` documented but not supported** — Doc was wrong. Removed `true` from the docs; valid values are `false`, `:low`, `:medium`, `:high`, `:max`, or `%{effort: level, budget: tokens}`.

6. `[FIXED]` **Process dictionary leaks in Loop** — `done_key` eliminated entirely by replacing the two-phase `Stream.concat` + process dictionary pattern with a direct `Stream.flat_map` callback. `cancel_ref` now cleaned up via `finish/2` helper at all terminal paths (`:done`, `:error`) and via `Process.delete` in the cancel function itself.

---

## Core Data Structs (Model, Context, Message, Response, Usage, Content blocks)

### Bugs / Correctness
- `[FIXED]` **tool_result.ex:29-35** — Added `nil -> []` clause in the content update function to match the documented behaviour.

### Inconsistencies
- `[WONTFIX]` **message.ex:24** — Typespec declares `timestamp: DateTime.t()` (non-nilable) but struct defaults to `nil`. All construction goes through `new/1` which always sets a timestamp, so the typespec accurately describes the intended contract.
- `[WONTFIX]` **model.ex:196 vs message.ex:38** — Constructor input handling inconsistency (see cross-cutting #4 — false positive).

### Dead Code
- `[DEFERRED]` **attachment.ex:11** — `opts` field is reserved for provider-specific metadata (citations, titles, file IDs). Documented its purpose; added to roadmap for future dialect wiring.

### Naming
- `[FIXED]` **tool_result.ex:16** — Changed type from `Thinking.t()` to `Attachment.t()`. Anthropic dialect already handles attachments in tool result content via recursive `encode_content/1`; other dialects correctly filter to text only.
- `[FIXED]` **model.ex:22-25** — Cost field docs say "per million tokens" but don't specify currency. Added "USD" to Model cost field docs and Usage cost field docs.

### Minor / Nits
- `[WONTFIX]` **context.ex:25** — Passthrough is in the typespec, sufficient documentation.
- `[WONTFIX]` **context.ex:28** — `new/0` producing an empty context is intentional convenience, not accidental.
- `[WONTFIX]` **response.ex:30** — Constructor shouldn't infer field relationships; caller is responsible for assembling params.
- `[WONTFIX]` **context.ex:14** — Typespecs define intended structure, not every possible runtime state.

---

## Streaming Pipeline (StreamingResponse, SSE Parser, NDJSON Parser)

### Bugs / Correctness
- `[WONTFIX]` **streaming_response.ex:508** — Flagged as double-counting cached tokens, but this is correct. Anthropic's `input_tokens` is the *non-cached* portion; cache tokens are additive. OpenAI/Google/Ollama don't extract cache tokens separately (always 0). Formula is correct for all providers.
- `[FIXED]` **sse.ex:24-26** — Upgraded to `Stream.transform/5` with a `last_fun` that flushes the buffer on stream end, matching the NDJSON parser pattern. Incomplete JSON in the buffer is safely skipped. Added tests for both cases.

### Inconsistencies
- `[FIXED]` **sse.ex:18 vs ndjson.ex:15** — Fixed docs to say `JSON.decode/1`.
- `[FIXED]` **streaming_response.ex:94** — Changed to `{event_type(), map(), Response.t()} | {:error, term(), Response.t()}` to precisely express that only error events carry a non-map second element.

### Dead Code
- `[FIXED]` **streaming_response.ex:126-127** — Removed the `%{error: nil}` fallback (truly unreachable). Kept a single `%{error: reason}` fallback — needed when mid-stream error is followed by block-end events from `finalize_blocks`, making the `:error` tuple not last. Added `when reason != nil` guard for precision.
- `[FIXED]` **ndjson.ex:37-39** — Simplified `process_chunk/2` to call `extract_lines/2` directly, removing the unnecessary single-branch case.

### Minor / Nits
- `[WONTFIX]` **streaming_response.ex:342** — `block_order ++ [key]` is O(n) on 1-5 elements. Reversing at read time would be worse since `build_response` is called on every delta. Correct tradeoff.
- `[FIXED]` **streaming_response.ex:461-474 vs 396-424** — Unified `partial_block/1` and `finalize_block/1` into single `build_block/1`. Removed unused `final?` parameter from `build_response`.
- `[WONTFIX]` **sse.ex:34** — A chunk can split `\r\n` across boundary (`\r` at end, `\n` at start of next), so the buffer must be re-normalized with each new chunk. Correct as-is.

---

## Tools & Schema (Tool, Tool.Runner, Schema)

### Bugs / Correctness
- `[FIXED]` **schema.ex:137-144** — Added `to_peri(%{type: "object"})` returning `:map` for free-form objects. Also added `object/1` builder accepting opts-only (no properties).
- `[FIXED]` **schema.ex:165** — Added `to_peri(%{type: "array"})` returning `:list` for free-form arrays. Also added `array/1` builder accepting opts-only (no items).
- `[FIXED]` **schema.ex:166** — Added `defp to_peri(_), do: :any` catch-all for unrecognized schema shapes.
- `[FIXED]` **schema.ex:153-157** — Number `to_peri` now uses `constrain/2` for consistency with integer and string. No behavioral change (Peri handles both forms) but matches the pattern used elsewhere.
- `[FIXED]` **tool.ex:148-155** — Narrowed `rescue` to only the handler call. Schema/validation bugs now raise (surfacing clearly) while handler exceptions are still caught as `{:error, exception}`.

### Inconsistencies
- `[FIXED]` **schema.ex:67-69** — `enum/2` no longer hardcodes `type: "string"`. Now type-agnostic per JSON Schema spec. `to_peri` handles `%{enum: values}` via Peri's `{:enum, values}` which validates `val in values` regardless of type.
- `[FIXED]` **tool/runner.ex:76** — Validation errors now use `Schema.format_errors`, handler exceptions use `Exception.message`. Both produce LLM-friendly output instead of opaque `inspect` format.
- `[FIXED]` **tool/runner.ex:38** — Added `:tool_timeout` option (default 30s) to `stream_text/3` and `generate_text/3`. Threaded through `Loop` into `Tool.Runner.run/3`. Default raised from 5s to 30s.

### Dead Code
- `[WONTFIX]` **schema.ex:113** — `format_errors(%{__struct__: _} = error)` handles a single struct. Kept because Peri's scalar validation path (`validate_field` returning `{:error, reason, info}`) wraps via `Peri.Error.new_single/2` which returns a bare struct, not a list.

### Minor / Nits
- `[FIXED]` **tool/runner.ex:90-91** — `format_result/1` now uses `JSON.encode!/1` with `inspect/1` fallback for non-serializable values.
- `[WONTFIX]` **tool.ex:131** — See cross-cutting #4 — false positive.
- `[FIXED]` **schema.ex:174-178** — Added docs to `validate/2` clarifying that property key types are preserved through validation and that builder options must be atom keywords.

---

## Dialects (AnthropicMessages, GoogleGemini, OllamaChat, OpenAICompletions, OpenAIResponses)

### Bugs / Correctness
- `[FIXED]` **anthropic_messages.ex:123** — Added `nil` clause to `normalize_stop_reason` and switched to `maybe_put` in `handle_event`, so nil stop reasons are skipped instead of falling through to the catch-all.
- `[FIXED]` **google_gemini.ex:58-59** — Already resolved in prior refactor. Separate clauses now match `%{budget: budget} when is_integer(budget)` vs `%{} = opts` (effort-only), so nil budget is never sent.
- `[FIXED]` **openai_responses.ex:261** — Added `handle_event` for `"response.failed"` that emits `{:error, message}`. Removed unreachable `infer_stop_reason(%{"status" => "failed"})` clause.
- `[DEFERRED]` **ollama_chat.ex:266-270** — URL-based image attachments silently skipped (Ollama has no URL input mechanism). Documented in Ollama provider moduledoc and `extract_images` comment. Warning mechanism added to roadmap.

### Inconsistencies
- `[FIXED]` **All dialects** — `normalize_thinking/1` eliminated. See cross-cutting #2.
- `[FIXED]` **All dialects** — `maybe_put/3` extracted to `Omni.Util`. See cross-cutting #3.
- `[FIXED]` **openai_completions.ex:85-87** — Moved usage handler below all choices handlers. `finish_reason` clause now also extracts usage from combined chunks (e.g. OpenRouter). Standalone usage handler catches the rest.
- `[WONTFIX]` **openai_completions.ex:228-234** — API limitation, not a bug. Chat Completions has no generic URL content type; `image_url` is the only URL-based input available. Added comment explaining the constraint.
- `[WONTFIX]` **ollama_chat.ex:299** — Ollama's API correlates tool results by `tool_name`, not by ID. Omitting `tool_use_id` is correct per the API spec.
- `[FIXED]` **openai_completions.ex:163** — Removed unused third accumulator from `split_assistant_content` in both Completions and Responses dialects. No assistant content types fall outside Text/ToolUse.

### Dead Code
- `[WONTFIX]` **google_gemini.ex:28** — Not redundant. `body` on its own line is the start of a `body |> maybe_put(...) |> ...` pipeline, not a trailing expression.
- `[FIXED]` **ollama_chat.ex:147** — Replaced `Enum.with_index |> Enum.map` with plain `Enum.map`.

### Minor / Nits
- `[FIXED]` **anthropic_messages.ex:165** — Replaced `String.contains?(id, "4.6")` with explicit `@adaptive_prefixes` module attribute list. Manually maintained as new models are released.
- `[FIXED]` **google_gemini.ex:68** — Added comment explaining `:max` downgrades to `"high"` (Gemini's highest level).
- `[FIXED]` **ollama_chat.ex:50-52** — Bug fix: all thinking levels now map to `true` for standard Ollama models. Only `gpt-oss` prefix models accept string levels (with `:max` → `"high"` downgrade). Added comments.
- `[FIXED]` **ollama_chat.ex:293-299** — `encode_tool_result` now prefixes content with `"Error: "` when `is_error` is true, since Ollama's API has no error field.

---

## Providers (Provider behaviour, Anthropic, Google, OpenAI, OpenRouter, Ollama)

### Bugs / Correctness
- `[FIXED]` **openrouter.ex:53** — Removed unreachable `"max" -> "xhigh"` conditional. The dialect already converts before `modify_body/3` runs; effort value is now passed through directly.
- `[FIXED]` **provider.ex:309-313** — MFA `resolve_auth/1` now validates the return is a binary, returning `{:error, {:invalid_auth_value, other}}` otherwise.

### Inconsistencies
- `[FIXED]` **openai.ex:36-40, openrouter.ex:74-78, ollama.ex:66-69** — Default `authenticate/2` now sends Bearer token when no `:auth_header` is configured, raw key when a custom header is set. Removed identical overrides from OpenAI, OpenRouter, and Ollama (Ollama retains only its nil-key skip clause).

### Dead Code
- `[FIXED]` **openrouter.ex:53** — Removed with the conditional (see Bugs above).

### Minor / Nits
- `[WONTFIX]` **provider.ex:389** — `String.to_existing_atom/1` fails at app startup because `:pdf` may not be in the atom table yet. `String.to_atom/1` is safe — JSON files are controlled and committed.
- `[FIXED]` **ollama.ex:76-81** — `provider` and `dialect` now merged after user attrs, so they can't be overridden. Only `:name` and capability fields are user-overridable.
- `[WONTFIX]` **openrouter.ex:80-96** — Positional coupling is safe: dialect's `encode_message/1` maps each assistant message to exactly one `"assistant"` wire message, preserving 1:1 order. User messages may split into multiple wire messages, but those are `"tool"` role, not `"assistant"`.

---

## Loop & Top-level API (Loop, Omni, Request)

### Bugs / Correctness
- `[FIXED]` **request.ex:174** — Replaced `hd()` with `Enum.any?/2`, safely handling missing or multiple content-type headers.
- `[FIXED]` **omni.ex:182** — `thinking: true` documented but not in schema. See cross-cutting #5.

### Inconsistencies
- `[FIXED]` **request.ex:10** — Module comment said `stream/2`, corrected to `stream/3`.
- `[FIXED]` **loop.ex:9** — Corrected module comment: hallucinated tool names produce error results and the loop continues; only schema-only tools break the loop.
- `[FIXED]` **loop.ex:263-273** — Not a bug. `:tool_result` events are synthetic (emitted by Loop between SR pipelines), so the previous step's completed response is the correct third element. Added clarifying note to StreamingResponse moduledoc.

### Dead Code
None found.

### Minor / Nits
- `[WONTFIX]` **loop.ex:118,146,213,218** — O(n²) message append is negligible: loops hit model context limits or memory before list append matters. Typical loops are 10-20 steps on lists of 20-40 messages.
- `[FIXED]` **loop.ex:54** — Process dictionary leaks. See cross-cutting #6.
- `[FIXED]` **request.ex:189** — Changed headers schema type from `:any` to `:map`, so Peri validates the type before merge.
- `[FIXED]` **loop.ex:279** — Eliminated `tool_result_text/1` entirely. `:tool_result` events now emit `%ToolResult{}` structs directly (consistent with Agent events), instead of decomposing into a map.

---

## Agent System (Agent, Executor, Server, State, Step)

### Bugs / Correctness
- `[FIXED]` **server.ex:129-136** — `next_prompt` now stores `{content, opts}` tuple. Opts are merged into `prompt_opts` when the queued prompt fires.
- `[FIXED]` **server.ex:531-541** — Renamed `all_executable?/2` to `any_schema_only?/2` (inverted). Logic is unchanged — hallucinated names correctly pass through to execution and get error results from `Tool.Runner`. The rename makes the intent explicit: the check is "are there schema-only tools that need manual handling?"
- `[FIXED]` **server.ex:267-269** — Removed the try/rescue in Executor and the `{:executor_error, ...}` handler in Server. Tool.Runner handles all per-tool failures internally; an executor crash (internal bug) is caught by the existing EXIT handler.
- `[FIXED]` **server.ex:244-258** — Listener now receives `{:agent, pid, :retry, reason}` before a retry, distinguishing it from terminal `:error`. Listener contract: `:error` = terminal (round over), `:retry` = non-terminal (more events will follow).

### Inconsistencies
- `[FIXED]` **server.ex:465-486** — `commit_and_done` now commits context then delegates to `reset_round`, eliminating the duplicated field list.

### Dead Code
- `[FIXED]` **server.ex:28** — Removed unused `@type t` from `@moduledoc false` module.

### Naming
- `[WONTFIX]` **server.ex:40** — `pending_messages` name kept; added comment clarifying it's buffered until committed on `:done`.

### Minor / Nits
- `[WONTFIX]` **server.ex:156,364** — O(n²) append within a single turn. Same reasoning as loop message appends — context limits hit first.
- `[FIXED]` **step.ex:48** — `rescue` now sends the exception struct instead of `Exception.message(e)`, preserving debuggability. The `throw`/`catch` for stream errors is correct — it's control flow to break out of `reduce` with non-exception error terms.
- `[WONTFIX]` **server.ex:490-497** — The catch-all `handle_info/2` at line 278 handles stale messages from killed tasks. This is standard GenServer practice; the catch-all's existence is the documentation.

---

## Supporting Code (Application, Mix Tasks)

### Bugs / Correctness
- `[WONTFIX]` **models.get.ex:47** — Jason is needed for `pretty: true` on generated JSON files (reviewed frequently in diffs). Elixir's built-in `JSON` module has no pretty-print option.

### Inconsistencies
- `[WONTFIX]` **models.get.ex:47 vs provider.ex:378** — Same as above.

### Minor / Nits
- `[FIXED]` **application.ex:10-11** — `Provider.load/1` now wraps `mod.models()` in try/rescue with a descriptive re-raise including provider id and module.
- `[FIXED]` **models.get.ex:43** — Bug: `filter_modalities` was defaulting nil/empty modalities to `["text"]`, incorrectly giving text capability to audio/video-only models. Now returns `[]` for nil and filters without defaults. The text filter on line 43 correctly excludes models without text input.
- `[WONTFIX]` **models.get.ex:93** — `|| false` is intentional: we want a boolean, not nil.
