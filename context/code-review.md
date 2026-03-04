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

2. **`normalize_thinking/1` duplicated across all 5 dialects** — Identical 4-line function copy-pasted in every dialect. Strong candidate for extraction into `Omni.Dialect` or a shared helper.

3. **`maybe_put/3` duplicated across all dialects** — Same private helper in every dialect module.

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
- **attachment.ex:11** — `opts: %{}` field on Attachment is never read, written, or referenced anywhere in the codebase. Remove or document its purpose.

### Naming
- **tool_result.ex:16** — Type includes `Thinking.t()` but no dialect ever produces/consumes Thinking blocks in ToolResults. Either document when this would occur or remove from the type.
- `[FIXED]` **model.ex:22-25** — Cost field docs say "per million tokens" but don't specify currency. Added "USD" to Model cost field docs and Usage cost field docs.

### Minor / Nits
- **context.ex:25** — Doc omits that passing `%Context{}` returns it unchanged (passthrough behavior undocumented).
- **context.ex:28** — `new([])` succeeds only accidentally because empty keyword list is valid for `struct!/2`.
- **response.ex:30** — Constructor doesn't auto-populate `messages` from `message`. Manual construction must set both.
- **context.ex:14** — Type declares `tools: [Tool.t()]` but `nil` is possible via direct construction. Consider `[Tool.t()] | nil`.

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
- **streaming_response.ex:342** — `block_order ++ [key]` is O(n) append. Negligible for typical responses (1-5 blocks).
- **streaming_response.ex:461-474 vs 396-424** — `partial_block/1` and `finalize_block/1` are nearly identical; `final?` flag doesn't actually change behavior. Could unify.
- **sse.ex:34** — `\r\n` normalization applied to entire `buffer <> chunk` on every chunk, even though buffer was already normalized.

---

## Tools & Schema (Tool, Tool.Runner, Schema)

### Bugs / Correctness
- **schema.ex:137-144** — `to_peri` for objects requires `properties` key. `%{type: "object"}` without properties (free-form object) crashes with `FunctionClauseError`. Fix: add clause returning `:map`.
- **schema.ex:165** — `to_peri` for arrays requires `items` key. `%{type: "array"}` without items crashes. Fix: add clause returning `:list`.
- **schema.ex:166** — No catch-all clause in `to_peri`. Any unrecognized schema shape (`"null"`, `oneOf`, `$ref`) raises opaque `FunctionClauseError`. Fix: add `defp to_peri(_), do: :any` or raise a descriptive error.
- **schema.ex:153-157** — Constrained `number` type doesn't use `constrain/2` helper, unlike `integer` and `string`. If Peri requires a bare tuple for single constraints, this would misvalidate.
- **tool.ex:148-155** — `rescue` covers both `validate_input` and `handler.(validated)`. Schema bugs in `to_peri` (above) get silently wrapped as `{:error, exception}` instead of surfacing clearly. Fix: narrow rescue to handler call only.

### Inconsistencies
- **schema.ex:67-69** — `enum/2` hardcodes `type: "string"` and spec declares `list(String.t())`. JSON Schema `enum` is type-agnostic. Internally consistent but limits use.
- **tool/runner.ex:76** — Validation errors from `Tool.execute` go through `inspect(error)`, producing opaque Elixir format sent to the LLM. Compare with `Loop:208` which uses `Schema.format_errors`. Fix: use `Schema.format_errors` for validation errors in runner too.
- **tool/runner.ex:38** — Default timeout of 5000ms is not configurable from `Omni.Loop`. No `:tool_timeout` in `Request.validate`. May surprise users with slow tools.

### Dead Code
- **schema.ex:113** — `format_errors(%{__struct__: _} = error)` handles a single struct, but Peri always returns errors as lists. Unreachable in normal flows.

### Minor / Nits
- **tool/runner.ex:90-91** — `format_result/1` uses `inspect/1` for non-binary values. `JSON.encode!/1` would produce more model-friendly output.
- `[WONTFIX]` **tool.ex:131** — See cross-cutting #4 — false positive.
- **schema.ex:174-178** — Entire module assumes atom-keyed schemas. Undocumented requirement for `validate/2`.

---

## Dialects (AnthropicMessages, GoogleGemini, OllamaChat, OpenAICompletions, OpenAIResponses)

### Bugs / Correctness
- **anthropic_messages.ex:123** — `normalize_stop_reason(delta["stop_reason"])` called unconditionally on `message_delta`. When `stop_reason` is `nil`, catch-all maps to `:stop`, prematurely setting stop reason. Other dialects guard with `when is_binary(reason)` or `maybe_put_stop_reason`. Fix: add nil guard.
- **google_gemini.ex:58-59** — `thinking: %{effort: :high}` (map form, no `:budget`) produces `%{"thinkingBudget" => nil}` sent to API. Anthropic has fallback (`budget || effort_to_budget(level)`), Gemini does not. Fix: fall back to `thinkingLevel` config when budget is nil.
- **openai_responses.ex:261** — `infer_stop_reason(%{"status" => "failed"})` returns `:error`, but no `handle_event` clause for `"response.failed"` — falls through to catch-all `do: []`. The API sends `response.failed` for failures, not `response.completed`. Fix: add `handle_event` for `"type" => "response.failed"` that emits `{:error, reason}`.
- **ollama_chat.ex:266-270** — URL-based image attachments silently dropped by `extract_images/1` (only matches `{:base64, data}`). Silent data loss for users providing `{:url, url}` to Ollama. Fix: raise or warn for unsupported URL sources.

### Inconsistencies
- **All dialects** — `normalize_thinking/1` is copy-pasted identically. See cross-cutting #2.
- **All dialects** — `maybe_put/3` duplicated. See cross-cutting #3.
- **openai_completions.ex:85-87** — `handle_event(%{"usage" => usage})` matches *any* event with usage key, potentially dropping choices data from combined chunks. In practice OpenAI separates these, but fragile for third-party providers.
- **openai_completions.ex:228-234** — Non-image URL attachments use `"type" => "image_url"` wrapper, which seems like a misuse of the type name.
- **ollama_chat.ex:299** — `encode_tool_result` omits `tool_use_id`. Results can't be correlated to specific tool calls in parallel tool use.
- **openai_completions.ex:163** — `split_assistant_content` returns third element `_other` that is always discarded at call site. Wasted accumulation. Same in `openai_responses.ex:140`.

### Dead Code
- **google_gemini.ex:28** — Trailing `body` after pipeline is redundant (pipeline already evaluates to result). Same pattern in `anthropic_messages.ex:39`, `openai_completions.ex:38`, `openai_responses.ex:38`.
- **ollama_chat.ex:147** — `Enum.with_index` used but index discarded. Use `Enum.map` instead.

### Minor / Nits
- **anthropic_messages.ex:165** — `adaptive_model?` uses `String.contains?(id, "4.6")` — fragile heuristic that will break with future models.
- **google_gemini.ex:68** — `level_string(:max)` returns `"high"` (silent downgrade). Worth a comment.
- **ollama_chat.ex:50-52** — `:high` and `:max` map to `true` (boolean) while `:low`/:medium` map to strings. Asymmetry is Ollama-specific but surprising without a comment.
- **ollama_chat.ex:293-299** — `encode_tool_result` ignores `is_error`. Ollama gets no error indication.

---

## Providers (Provider behaviour, Anthropic, Google, OpenAI, OpenRouter, Ollama)

### Bugs / Correctness
- `[FIXED]` **openrouter.ex:53** — Removed unreachable `"max" -> "xhigh"` conditional. The dialect already converts before `modify_body/3` runs; effort value is now passed through directly.
- `[FIXED]` **provider.ex:309-313** — MFA `resolve_auth/1` now validates the return is a binary, returning `{:error, {:invalid_auth_value, other}}` otherwise.

### Inconsistencies
- **openai.ex:36-40, openrouter.ex:74-78, ollama.ex:66-69** — Three providers have identical Bearer-style `authenticate/2` overrides. The macro default uses raw key (Anthropic/Google style). Majority case (Bearer) requires override, minority case is the default. Consider making Bearer the default.

### Dead Code
- **openrouter.ex:53** — True branch of `if effort == "max"` (see Bugs above).

### Minor / Nits
- **provider.ex:389** — `String.to_atom/1` on modality strings from JSON. Safe since files are controlled, but `String.to_existing_atom/1` would be more defensive.
- **ollama.ex:76-81** — `build_model/1` allows overriding `:provider` and `:dialect` via user attrs, creating potential mismatch with persistent_term key.
- **openrouter.ex:80-96** — `attach_reasoning_details/2` assumes assistant messages appear in same positional order in context and wire-format body. Implicit coupling with dialect.

---

## Loop & Top-level API (Loop, Omni, Request)

### Bugs / Correctness
- **request.ex:174** — `select_parser/1` calls `hd()` on `get_header("content-type")` which returns `[]` for missing headers. `hd([])` raises `ArgumentError`. Fix: add fallback for empty list.
- **omni.ex:182** — `thinking: true` documented but not in schema. See cross-cutting #5.

### Inconsistencies
- **request.ex:10** — Module comment says `stream/2` but function is `stream/3`.
- **loop.ex:9** — Module comment says loop breaks on hallucinated tool names, but code shows hallucinated names produce error results and loop continues. Only schema-only tools break the loop.
- **loop.ex:263-273** — `:tool_result` event passes previous step's response as third tuple element, but StreamingResponse documents third element as partial response of current state.

### Dead Code
None found.

### Minor / Nits
- **loop.ex:118,146,213,218** — Repeated `state.messages ++ [msg]` is O(n) per step, O(n^2) total. Fine for typical use but suboptimal for long agentic loops.
- `[FIXED]` **loop.ex:54** — Process dictionary leaks. See cross-cutting #6.
- **request.ex:189** — `merge_config(:headers, a, b)` crashes if either value is not a map. Schema types headers as `:any` with no protection.
- **loop.ex:279** — `tool_result_text/1` only matches `%Text{}`. A ToolResult with Thinking content would crash. Add catch-all.

---

## Agent System (Agent, Executor, Server, State, Step)

### Bugs / Correctness
- **server.ex:129-136** — `prompt/3` while running/paused silently discards `opts`. Staged prompt replaces `next_prompt` but caller-supplied opts (e.g. `max_steps: 50`) are lost. Fix: store `next_prompt` as `{content, opts}` tuple.
- **server.ex:531-541** — `all_executable?/2` returns `true` for hallucinated tool names (nil from map lookup). If model sends a mix of hallucinated + schema-only tools, `all_executable?` returns false (schema-only fails check), and the whole batch goes to `finalize_turn` — losing the hallucinated tool's error feedback entirely.
- **server.ex:267-269** — `{:executor_error, reason}` calls `reset_round` which discards the assistant message already appended to `pending_messages`. Partial work vanishes silently. Consider calling `handle_error` here like for step errors.
- **server.ex:244-258** — On step crash + retry, events from the crashed attempt were already forwarded to the listener. Retry produces duplicate/overlapping events with no indication the first batch was invalid.

### Inconsistencies
- **server.ex:465-486** — `commit_and_done` manually resets every field, duplicating `reset_round`'s field list. New fields must be updated in both places. Maintenance risk.

### Dead Code
- **server.ex:28** — `@type t :: %__MODULE__{}` defined but never referenced. Module is `@moduledoc false`. Can remove.

### Naming
- **server.ex:40** — `pending_messages` lifecycle semantics are subtle (buffer until commit). `round_messages` or `uncommitted_messages` might better convey the buffering pattern.

### Minor / Nits
- **server.ex:156,364** — `rejected_results ++ [result]` appends in a loop. O(n^2) for many rejected tools.
- **step.ex:48, executor.ex:23** — `Exception.message(e)` discards exception struct and stack trace. Loses debuggability.
- **server.ex:490-497** — Window between `kill_task` and `reset_round` where stale messages can arrive. Silently dropped by catch-all. Correct but worth a comment.

---

## Supporting Code (Application, Mix Tasks)

### Bugs / Correctness
- `[WONTFIX]` **models.get.ex:47** — Jason is needed for `pretty: true` on generated JSON files (reviewed frequently in diffs). Elixir's built-in `JSON` module has no pretty-print option.

### Inconsistencies
- `[WONTFIX]` **models.get.ex:47 vs provider.ex:378** — Same as above.

### Minor / Nits
- **application.ex:10-11** — If a provider's `models/0` raises during startup (corrupt JSON), the error is opaque. Consider wrapping with descriptive re-raise.
- **models.get.ex:43** — `Enum.filter(&("text" in &1["input_modalities"]))` is effectively unreachable filtering — `filter_modalities/2` already defaults empty/nil to `["text"]`.
- **models.get.ex:93** — `model["reasoning"] || false` converts explicit `nil` to `false`. `Map.get(model, "reasoning", false)` would be more precise.
