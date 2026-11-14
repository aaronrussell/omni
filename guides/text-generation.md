# Text generation

Text generation is a conversation: you send a context, the model writes the next message. This guide covers what goes into the context, how to read and stream what comes back, and the features built on top: thinking, tools and structured output.

Two functions do the work. `Omni.generate_text/3` returns the finished response. `Omni.stream_text/3` returns a stream of events as the model writes. Both take a model, a context and options.

## Contexts and messages

The context is what the model sees: an optional system prompt, the messages so far, and any tools. For a single prompt, a string is enough:

```elixir
{:ok, response} = Omni.generate_text("openai:gpt-6.1-sol", "Name three Elixir web frameworks.")
```

For anything more, build a context:

```elixir
context =
  Omni.context(
    system: "You answer in one sentence.",
    messages: [Omni.message("Name three Elixir web frameworks.")]
  )

{:ok, response} = Omni.generate_text("openai:gpt-6.1-sol", context)
```

A message has a role, `:user` or `:assistant`, and a list of content blocks. `Omni.message/1` takes a string for a user message, or `role:` and `content:`.

To carry a conversation on, push the response onto the context and add the next user message:

```elixir
context =
  context
  |> Omni.Context.push(response)
  |> Omni.Context.push(Omni.message("Which is the oldest?"))

{:ok, response} = Omni.generate_text("openai:gpt-6.1-sol", context)
```

Omni keeps no state between requests. The context is yours to hold, store and trim. For persistence, `Omni.Codec` turns messages into JSON-safe maps and back without loss.

## Images and PDFs

A user message can mix text with attachments. An attachment is a source, `{:base64, data}` or `{:url, url}`, and a media type:

```elixir
message =
  Omni.message(
    role: :user,
    content: [
      "What's in this image?",
      Omni.attachment({:base64, Base.encode64(File.read!("photo.png"))}, "image/png")
    ]
  )

{:ok, response} = Omni.generate_text("google:gemini-3.5-flash", [message])
```

Each model lists what it accepts in `model.input_modalities` (`:text`, `:image`, `:pdf`). Sending an attachment the model doesn't accept returns `{:error, {:unsupported_modality, :image}}` before any request is made.

## The response

`Omni.generate_text/3` returns an `Omni.Response`:

- `message` is the assistant's message, and `messages` every message the request produced. They differ when tools ran: `messages` then holds each tool use and tool result along the way.
- `stop_reason` says why the model stopped: `:stop`, `:length` (it hit the token limit), `:tool_use`, `:refusal`, `:error` or `:cancelled`.
- `usage` holds token counts and their cost in USD, worked out from the model's pricing.
- `output` holds the decoded map when you asked for [structured output](#structured-output).

## Streaming

`Omni.stream_text/3` returns an `Omni.StreamingResponse` once the provider starts to answer. There are three ways to consume it.

Register handlers for the events you care about, then run the stream to its end:

```elixir
alias Omni.StreamingResponse

{:ok, stream} = Omni.stream_text("anthropic:claude-sonnet-5-5", "Tell me a story")

{:ok, response} =
  stream
  |> StreamingResponse.on(:text_delta, fn %{delta: text} -> IO.write(text) end)
  |> StreamingResponse.complete()
```

Take only the text:

```elixir
stream
|> StreamingResponse.text_stream()
|> Enum.each(&IO.write/1)
```

Or enumerate every event. Each is `{type, data, partial_response}`, where the partial response is the response as built so far:

```elixir
for {type, data, _partial} <- stream do
  case type do
    :text_delta -> IO.write(data.delta)
    :tool_use_start -> IO.puts("Using #{data.name}")
    :done -> IO.puts("\nStopped: #{data.stop_reason}")
    _ -> :ok
  end
end
```

Text, thinking and tool use blocks each arrive as a `_start`, any number of `_delta`s and an `_end`. A stream finishes with one `:done` or one `:error`. `Omni.StreamingResponse` lists every event and its data.

The stream is lazy and runs in your process, so nothing is read until you consume it. To stop early, call `StreamingResponse.cancel/1`.

## Thinking

Many models can reason before they answer. The `:thinking` option asks for it:

```elixir
{:ok, response} =
  Omni.generate_text("anthropic:claude-sonnet-5-5", "How many primes are there below 100?", thinking: :high)
```

- An effort level: `:low`, `:medium`, `:high`, `:xhigh` or `:max`.
- `true` is the same as `:medium`.
- `false` switches thinking off, on models that can switch it off.
- `%{effort: :high, budget: 20_000}` sets an exact token budget, on models that take one.

Models differ in what they accept, and Omni translates for each. A level the model doesn't have is rounded to the nearest it does. A model that takes a token budget is given one sized to the level. A model that doesn't reason ignores the option. `model.thinking` shows what a model supports (see `Omni.Model`).

Reasoning comes back as `Omni.Content.Thinking` blocks, and streams as `:thinking_delta` events. Some providers return a summary, some return it encrypted, and some return nothing readable.

Keep those blocks in the conversation: on later turns Omni sends them back, which models need to continue their reasoning across tool use. They only go back to the provider and [dialect](providers-and-models.md#three-ideas) that wrote them. If you switch model mid-conversation, earlier thinking is left out and the text and tool uses are kept.

## Tools

Tools let the model call your code. A tool has a name, a description that tells the model when to use it, a schema for its input, and a handler:

```elixir
weather =
  Omni.tool(
    name: "get_weather",
    description: "Gets the current weather for a city",
    input_schema: Omni.Schema.object(%{city: Omni.Schema.string()}, required: [:city]),
    handler: fn input -> Weather.current(input.city) end
  )

context =
  Omni.context(
    messages: [Omni.message("Do I need an umbrella in London?")],
    tools: [weather]
  )

{:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", context)
```

When the model answers with tool uses, Omni validates each input against the schema, runs the handlers in parallel, and sends the results back in a new user message. This loop repeats until the model answers with `stop_reason: :stop`. The response you get is the final one; `response.messages` holds every step, and `response.usage` is the total.

The handler receives input with the schema's own keys. It may return any term. A handler that raises, or a tool name the model made up, becomes an error result the model can read and recover from.

Three options shape the loop:

- `:max_steps` caps the number of requests (default `:infinity`). Set `max_steps: 1` to manually handle the tool loop.
- `:tool_timeout` is how long each tool may run, in milliseconds (default `30_000`).
- When streaming, a `:tool_result` event is emitted for each result between steps.

### Tool modules

For a tool you reuse, define a module. It keeps the schema and the code together, and can take state when it is built:

```elixir
defmodule MyApp.Tools.FindOrder do
  use Omni.Tool,
    name: "find_order",
    description: "Looks up an order by its number"

  def schema do
    import Omni.Schema
    object(%{number: string()}, required: [:number])
  end

  def init(repo), do: repo

  def call(input, repo), do: repo.get_by(Order, number: input.number)
end

context =
  Omni.context(
    messages: messages,
    tools: [MyApp.Tools.FindOrder.new(MyApp.Repo)]
  )
```

`Omni.Tool` covers stateless tools, descriptions and schemas that depend on state, and other schema validators.

### Running tools yourself

A tool with no handler is one the model may ask for but Omni won't run. The loop stops and the response comes back with `stop_reason: :tool_use` and the `Omni.Content.ToolUse` blocks in its message. This suits tools that need a person's approval, or that run somewhere else. Answer each tool use with a tool result in the next user message:

```elixir
results =
  for %Omni.Content.ToolUse{} = tool_use <- response.message.content do
    Omni.tool_result(tool_use_id: tool_use.id, name: tool_use.name, content: run(tool_use))
  end

context =
  context
  |> Omni.Context.push(response)
  |> Omni.Context.push(Omni.message(role: :user, content: results))
```

To stop the loop for tools that do have handlers, pass `max_steps: 1`. `Omni.Tool.Runner` then runs a list of tool uses for you, with the same validation and timeouts the loop applies.

## Structured output

Pass a JSON Schema as `:output` to get data instead of prose:

```elixir
schema =
  Omni.Schema.object(
    %{
      sentiment: Omni.Schema.enum(["positive", "neutral", "negative"]),
      topics: Omni.Schema.array(Omni.Schema.string())
    },
    required: [:sentiment, :topics]
  )

{:ok, response} = Omni.generate_text("openai:gpt-6.1-sol", review_text, output: schema)

response.output
#=> %{sentiment: "negative", topics: ["delivery", "refunds"]}
```

The schema goes to the provider, which constrains the model to it where the provider can. Omni then decodes the answer and validates it against the schema. If it doesn't fit, Omni tells the model what was wrong and asks again, up to three times.

`Omni.Schema` has builders for the common JSON Schema types, and any map in JSON Schema form works. Keys in `response.output` are the keys you wrote in the schema.

Omni's own validator is meant for schemas of simple shape, and `Omni.Schema.validate/2` lists what it checks. For a schema that needs more, such as exact `oneOf`, recursive `$ref` or checked date formats, or to validate with a library you already use, such as [JSV](https://hex.pm/packages/jsv), pass a `{module, state}` adapter as `:output`. `Omni.Schema.Adapter` shows how to write one.

## Prompt caching

A long system prompt or conversation costs less, and answers sooner, when the provider caches it. Some providers cache on their own. Others, Anthropic among them, cache only when asked:

```elixir
Omni.generate_text("anthropic:claude-sonnet-5-5", context, cache: :short)
```

`:short` is the provider's standard cache lifetime, a few minutes. `:long` asks for its extended one where it has one: an hour on Anthropic, a day on OpenAI. `response.usage` reports `cache_read_tokens` and `cache_write_tokens`.

## Options

Every text request takes these:

| Option | What it does |
| --- | --- |
| `:max_tokens` | The most tokens the model may write |
| `:temperature` | Sampling temperature |
| `:thinking` | Reasoning effort (see [Thinking](#thinking)) |
| `:output` | A schema for structured output |
| `:cache` | `:short` or `:long` prompt caching |
| `:max_steps` | The most requests the tool loop may make |
| `:tool_timeout` | Milliseconds each tool may run |
| `:timeout` | Milliseconds to wait for each chunk of the response (default `300_000`) |
| `:api_key` | A key for this request |
| `:host` | Another origin for this request, such as `"http://localhost:4000"` |
| `:headers` | Extra request headers |
| `:metadata` | A map passed to the provider |
| `:raw` | When `true`, keeps each raw request and response on `response.raw` |

`Omni.stream_text/3` documents each in full.

## Errors

Both functions return `{:ok, result}` or `{:error, reason}`. Problems Omni can see before sending (an unknown model, a bad option, an attachment the model can't take, no API key) are errors with no request made. An HTTP error from the provider is `{:error, {:http_error, status, body}}`. A stream that ends without the model finishing is `{:error, :incomplete_stream}`.
