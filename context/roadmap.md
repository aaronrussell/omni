# Omni Roadmap

**Last updated:** February 2026

The initial implementation (Phases 1–5b) is complete. See `context/design.md` for the full architecture. This document tracks open questions and future work.

---

## Tool Calling Loop

**Status:** Implemented.

### Decision: No new functions

Tool looping is built into `stream_text/3` and `generate_text/3`. When tools are present in the context, the functions auto-execute tool uses and loop until the model stops calling tools. No separate `run/3` or `stream_text_with_tools/3` — this avoids function proliferation (especially once structured output is added).

- **`max_steps:` option** — Controls the maximum number of tool-calling rounds. Defaults to `:infinity` (or a high safety cap). Pass `max_steps: 1` for manual tool handling (opt out of auto-looping).
- **Backward compatible** — When no tools are in the context, behaviour is identical to today. The loop only activates when tools are present and the model produces tool use blocks.

### Loop mechanics

1. Execute the request, stream all events to the consumer.
2. On stream completion, check for tool use blocks in the accumulated response.
3. If tool uses: execute tools via `Tool.execute/2`, emit synthetic `:tool_result` events, build a user message with `ToolResult` blocks, append assistant + user messages to context, loop to step 1.
4. If no tool uses, or `max_steps` reached, or stop reason is `:stop`: stream ends.

- **Tool execution errors** go back to the model as error content in the `ToolResult` (not raised). `Tool.execute/2` already catches errors for this purpose.
- **Parallel tool use** is when the model returns multiple tool use blocks in one response. All are executed and all results are returned in the next user message. Sequential execution for v1; parallel (`Task.async_stream`) is a future optimization.

### Response shape

The `Response` struct gains a `:messages` field:

```elixir
%Response{
  message: %Message{role: :assistant, ...},   # Last assistant message
  usage: %Usage{...},                          # Aggregated across all rounds
  messages: [                                  # Full conversation sequence from this call
    %Message{role: :assistant, content: [%Text{}, %ToolUse{}, ...]},
    %Message{role: :user, content: [%ToolResult{}, ...]},
    %Message{role: :assistant, content: [%Text{}]}
  ]
}
```

- `response.message` is always `List.last(response.messages)` — a convenience reference.
- `response.usage` aggregates token counts and costs across all rounds.
- For a single-step call (no tools or `max_steps: 1`), `messages` is `[response.message]`.
- Continuing the conversation: append `response.messages` to the context.
- Per-step usage/metadata is available via `StreamingResponse.on/3` handlers during streaming, not baked into the Response.
- When `raw: true`, the `:raw` field becomes a list of `{%Req.Request{}, %Req.Response{}}` tuples (one per round).
- If `max_steps` is reached with pending tool uses, the response returns with a `:tool_use` stop reason. The user can continue manually.

### Streaming

All events from all rounds are flattened into a single `StreamingResponse`. Existing infrastructure (`on/3`, `complete/1`, `text_stream/1`, `cancel/1`) works unchanged. Between rounds, synthetic `:tool_result` events are emitted for observability:

```elixir
{:ok, sr} = Omni.stream_text(model, context)

sr
|> StreamingResponse.on(:text_delta, fn e, _ -> IO.write(e.text) end)
|> StreamingResponse.on(:tool_result, fn e, _ -> Logger.info("#{e.name} executed") end)
|> StreamingResponse.complete()
```

---

## Structured Output

**Status:** Not yet designed. Capture here for future reference.

Structured output would allow the model to return data conforming to a schema. Likely API shape: an `output:` option on `stream_text/3` / `generate_text/3` rather than separate `stream_object` / `generate_object` functions (same rationale as the tool loop — avoid function proliferation).

This has a looping element: validate the generated output against the schema, and if invalid, feed the validation error back to the model and retry. Analogous to the tool loop but with a different trigger — schema validation failure instead of tool use. A `max_retries:` option (distinct from `max_steps:`) would govern this. Both loops use the same underlying append-to-context-and-retry machinery, and they may compose: a call with tools AND structured output could tool-loop several times, then validate the final output against the schema.

---

## Pre-v1 Checklist

- **Code review** — Full pass over all modules for consistency, naming, edge cases, and dead code.
- **Test review** — Audit test coverage, identify gaps, ensure integration tests cover all providers and edge cases.
- **Documentation review** — Review all `@moduledoc`, `@doc`, and `@typedoc` annotations. Ensure top-level API functions have examples. Check ExDoc output.

---

## Future Work

- **Additional providers** — Groq, Together, Fireworks, Bedrock, Azure, Vertex AI. Each is a small module once the infrastructure exists.
- **Audio and video modalities** — models.dev has these columns but they are currently filtered out in `Model.new/1`. Needs investigation into encoding requirements and provider support before adding `:audio` and `:video` to `@supported_input_modalities`.
- **Agent capabilities** — Goal-orientation, hooks, error recovery, observability. Needs further design work.
