# Omni

Unified Elixir client for LLM APIs.
Text generation, tool use, and agents - across every provider.

## Features

- **Multi-provider** — Anthropic, OpenAI, Google Gemini, and OpenRouter out of the box
- **Streaming-first** — all requests stream by default; `generate_text` is built on `stream_text`
- **Tool use** — define tools with schemas and handlers; the loop auto-executes and feeds results back
- **Structured output** — JSON Schema validation with constrained decoding and automatic retries
- **Agents** — stateful, multi-turn GenServer with lifecycle callbacks, tool approval, and pause/resume
- **Extensible** — add custom providers by implementing a behaviour

## Installation

Add Omni to your dependencies:

```elixir
def deps do
  [
    {:omni, "~> 1.0"}
  ]
end
```

Each built-in provider reads its API key from a standard environment variable
by default — if your keys are set, no configuration is needed:

| Provider | Environment variable |
| --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google | `GEMINI_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |

Anthropic, OpenAI, and Google are loaded by default. To add others or limit
what loads at startup:

```elixir
config :omni, :providers, [:anthropic, :openai, :openrouter]
```

## Quick start

### Text generation

Pass a model tuple and a string:

```elixir
{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

response.message
#=> %Omni.Message{role: :assistant, content: [%Omni.Content.Text{text: "Hello! How can..."}]}
```

### Streaming

`stream_text` returns a `StreamingResponse` that you consume with event handlers:

```elixir
{:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Tell me a story")

{:ok, response} =
  stream
  |> Omni.StreamingResponse.on(:text_delta, fn %{delta: text} -> IO.write(text) end)
  |> Omni.StreamingResponse.complete()
```

### Tool use

Define tools with schemas and handlers — the loop automatically executes tool
uses and feeds results back to the model:

```elixir
weather_tool = Omni.tool(
  name: "get_weather",
  description: "Gets the current weather for a city",
  input_schema: Omni.Schema.object(
    %{city: Omni.Schema.string(description: "City name")},
    required: [:city]
  ),
  handler: fn input -> "72°F and sunny in #{input.city}" end
)

context = Omni.context(
  messages: [Omni.message("What's the weather in London?")],
  tools: [weather_tool]
)

{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, context)
```

### Agents

Wrap the generation loop in a supervised process with lifecycle callbacks:

```elixir
{:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-sonnet-4-5-20250514"})
:ok = Omni.Agent.prompt(agent, "Hello!")

# Events arrive as process messages
receive do
  {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
  {:agent, ^agent, :done, response} -> IO.puts("\nDone!")
end
```

Define a callback module with `use Omni.Agent` to customize behaviour —
control tool approval, handle stop reasons, manage state across turns, and
more. See the `Omni.Agent` documentation for the full callback API.

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/omni).

## License

This package is open source and released under the [Apache-2 License](https://github.com/aaronrussell/omni/blob/master/LICENSE).

© Copyright 2024-2026 [Push Code Ltd](https://www.pushcode.com/).
