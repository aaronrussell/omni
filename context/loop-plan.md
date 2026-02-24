# Request Loop — Implementation Plan

## Context

Omni's core streaming pipeline is complete (Phases 1–5b). The next feature is an automated request loop: when tools are present in the context, `stream_text/3` and `generate_text/3` should auto-execute tool uses and loop until the model stops calling tools. This loop module is intentionally general — future structured output validation retries will reuse the same machinery.

No new top-level functions. `stream_text/3` always delegates to the loop module, which handles both single-step and multi-step flows.

## Streaming Architecture

The core challenge: yield events lazily (real-time streaming) within each step while detecting step completion to decide whether to loop. No buffering, no spawned processes.

**Approach: Recursive stream concatenation**

For each step, wrap the inner SR's stream to intercept `:done` (capture in process dictionary, suppress from consumer). After the step's stream is exhausted, a lazy thunk (`Stream.flat_map([:_], fn :_ -> ... end)`) evaluates — checks the captured response, executes tools if needed, and either recursively builds the next step's stream or emits the final `:done`.

```
Consumer pulls events from:
  Stream.concat(step_1_events, thunk)
    thunk → execute tools → emit :tool_result events →
      Stream.concat(tool_results, Stream.concat(step_2_events, thunk))
        thunk → no more tools → emit {:done, ..., aggregated_response}
```

Single lazy pipeline. All existing SR infrastructure (`on/3`, `complete/1`, `text_stream/1`, `cancel/1`) works unchanged.

## Implementation Steps

### 1. Add `:messages` field to Response, change `:raw` type

**File:** `lib/omni/response.ex`

- Add `messages: []` to defstruct (not enforced)
- Update type: `messages: [Message.t()]`, `raw: [{Req.Request.t(), Req.Response.t()}] | nil`
- Update moduledoc to describe `messages` (all messages from the call — assistant + tool-result user messages; for single-step, `[response.message]`)

### 2. Set `messages` and wrap `raw` in StreamingResponse finalize

**File:** `lib/omni/streaming_response.ex`

In `finalize_done/1` (line 244), add:
```elixir
response = %{response | messages: [response.message]}
response = if acc.raw, do: %{response | raw: [acc.raw]}, else: response
```

(Changes the existing `raw: acc.raw` to `raw: [acc.raw]` — wraps the tuple in a list.)

Add `:tool_result` to the `@type event_type` union and to the moduledoc's consumer events section.

### 3. Fix existing tests for new Response shape

- `test/omni/streaming_response_test.exs` — update assertions: `resp.messages == [resp.message]`, `resp.raw` is now a list of tuples
- `test/integration/error_test.exs` — update raw assertion to expect `[{req, resp}]`
- Any other tests asserting on `Response.raw` shape

Run `mix test` to verify nothing breaks before proceeding.

### 4. Create `Omni.Loop` module

**New file:** `lib/omni/loop.ex`

General-purpose request loop. Currently handles tool auto-execution; designed to later support structured output validation retries using the same machinery.

Public API:
```elixir
@spec stream(Model.t(), Context.t(), keyword(), boolean(), pos_integer() | :infinity) ::
        {:ok, StreamingResponse.t()} | {:error, term()}
def stream(model, context, opts, raw?, max_steps)
```

The loop always builds and executes the first request. After the response, it decides whether to loop based on the response content. This means `stream_text/3` unconditionally delegates to `Loop.stream/5` — no conditional check in the caller.

Uses a `%{...}` state map to avoid parameter bloat:
```elixir
%{
  model: model, context: context, opts: opts, raw?: raw?,
  max_steps: max_steps, step_num: 1,
  cancel_key: make_ref(), tool_map: build_tool_map(context.tools),
  messages: [], raws: [], usage: %Usage{}
}
```

Key private functions:

- **`step/4`** — Calls `Request.build/3` then `Request.stream/3`, returns `{:ok, sr}`.

- **`loop_stream/2`** — `(sr, state)` → builds `Stream.concat(step_events, continuation)`:
  - `step_events`: `Stream.flat_map(sr.stream, ...)` — yields all events, suppresses `:done` (captured in process dict via a per-step `make_ref()` key)
  - `continuation`: `Stream.flat_map([:_], fn :_ -> handle_step_result(...) end)` — lazy thunk

- **`handle_step_result/2`** — `(response, state)`:
  - Extract `ToolUse` blocks from `response.message.content`
  - Accumulate: `messages ++ [response.message]`, `Usage.add(usage, response.usage)`, `raws ++ (response.raw || [])`
  - Check `should_loop?/3`: tool_uses present AND stop_reason is `:tool_use` AND step_num < max_steps AND `all_executable?/2` (see below)
  - If looping:
    - Execute tools → build ToolResult blocks
    - Emit `{:tool_result, event_data, response}` events
    - Build user message with ToolResults, append to context
    - `step/4` for next request, update cancel ref
    - Return `Stream.concat(tool_result_events, loop_stream(next_sr, updated_state))`
  - Else: emit `[{:done, %{stop_reason: ...}, final_response}]` with aggregated messages/usage/raw

- **`all_executable?/2`** — `(tool_uses, tool_map)` → checks whether ALL tool uses can be auto-executed. Specifically: if ANY tool use references a tool in context that has a `nil` handler (schema-only tool), returns false. The loop breaks and the response returns to the user with `:tool_use` stop_reason — this is a normal (non-error) response. The user provided the tool without a handler intentionally and handles execution manually.

  Note: a tool use referencing a name NOT in the context (hallucinated name) does NOT break the loop. This is a model error — the loop continues and sends an error ToolResult back to the model so it can retry.

- **`execute_tools/2`** — `(tool_uses, tool_map)` → maps each ToolUse to a ToolResult. Only called when `all_executable?` is true:
  - Tool found with handler: `Tool.execute/2` → `{:ok, result}` or `{:error, err}` → ToolResult
  - Tool not found (hallucinated name): ToolResult with `is_error: true`, content `"Tool not found: #{name}"` — sent back to model for retry
  - On execution error: ToolResult with `is_error: true` (error result goes back to model for retry)
  - Result formatting: binary passthrough, else `inspect/1`

- **`build_tool_result_events/2`** — synthetic `:tool_result` consumer events:
  ```elixir
  {:tool_result, %{name: name, tool_use_id: id, output: "result string", is_error: false}, response}
  ```

- **Cancel function:** Process dictionary holds current SR's cancel fn, updated each step. Outer cancel reads from it.

### 5. Simplify `Omni.stream_text/3`

**File:** `lib/omni.ex`

`stream_text` always delegates to `Loop.stream/5`. No conditional branching — the loop module handles single-step and multi-step uniformly:

```elixir
def stream_text(%Model{} = model, context, opts) do
  context = Context.new(context)
  {raw, opts} = Keyword.pop(opts, :raw, false)
  {max_steps, opts} = Keyword.pop(opts, :max_steps, :infinity)

  Loop.stream(model, context, opts, raw, max_steps)
end
```

`generate_text/3` is unchanged — it already delegates to `stream_text` + `complete`.

Update `@doc` for `stream_text/3` to document `:max_steps` option.

Note: `max_steps` is popped before reaching the loop module, NOT added to `@schema` — it's a loop-level concern, not a provider/dialect option. Consistent with how `:raw` is handled.

### 6. Integration tests

**New file:** `test/integration/loop_test.exs`

Uses stateful `Req.Test.stub` with an Agent counter to return tool_use fixture on first call, text fixture on second.

Test cases:
- **Auto-executes tools and returns final text** — 2-step loop, assert `response.messages` has 3 messages (assistant tool_use, user tool_result, assistant text), usage is aggregated, `response.message == List.last(response.messages)`
- **`max_steps: 1` bypasses looping** — returns tool_use response as-is, `messages: [message]`
- **`:tool_result` events emitted** — use `on(:tool_result, ...)` to capture synthetic events during streaming
- **`max_steps` caps the loop** — stub always returns tool_use, set `max_steps: 3`, assert 5 messages (3 assistant + 2 user), stop_reason is `:tool_use`
- **Tool without handler breaks loop** — context has a schema-only tool (no handler), assert response returned with `:tool_use` stop_reason, no error
- **Hallucinated tool name sends error to model** — tool_use references a name not in context, assert loop continues (error ToolResult sent to model, second step completes with text)
- **`raw: true` collects all request/response pairs** — assert `length(response.raw) == 2` for a 2-step loop
- **Usage aggregation** — verify `response.usage.total_tokens` > single-step usage
- **No tools in context** — single-step, `messages: [message]`, normal behavior

### 7. Unit tests

**New file:** `test/omni/loop_test.exs`

Test through the public `Loop.stream/5` interface using Req.Test stubs with SSE fixtures.

### 8. Documentation updates

- `lib/omni.ex` — `stream_text/3` docs: add `:max_steps` option
- `lib/omni/response.ex` — moduledoc: describe `messages` field
- `lib/omni/streaming_response.ex` — moduledoc: document `:tool_result` event
- `context/roadmap.md` — mark tool calling loop as implemented
- `CLAUDE.md` — add `loop.ex` to module layout

## Edge Cases

| Case | Handling |
|------|----------|
| `:tool_use` stop_reason but no ToolUse blocks | Don't loop (`tool_uses != []` check) |
| Tool not found in context (hallucinated) | ToolResult with `is_error: true` sent back to model, loop continues |
| Tool found but no handler (schema-only) | Loop breaks, returns response with `:tool_use` stop_reason to user |
| Tool execution raises | `Tool.execute/2` catches → ToolResult with `is_error: true`, model retries |
| `Request.build` fails in subsequent step | Emit `{:error, ...}` event, stop loop |
| Cancel during multi-step | Cancels currently-active HTTP request via mutable cancel ref |
| `raw: false` (default) | `raws` accumulator stays empty, final `raw` is `nil` |
| No tools in context | Single iteration, no looping overhead beyond the thunk check |

## Verification

1. `mix test` — all existing tests pass after Response/SR changes (step 3)
2. `mix test test/integration/loop_test.exs` — new integration tests pass
3. `mix test test/omni/loop_test.exs` — unit tests pass
4. `mix test` — full suite green
5. `mix format --check-formatted` — formatting clean
6. Manual: `mix test --include live` with API keys to verify real multi-step loops
