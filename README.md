# Omni

![Omni](https://raw.githubusercontent.com/aaronrussell/omni/main/media/poster.webp)

![Hex.pm](https://img.shields.io/hexpm/v/omni?color=informational)
![License](https://img.shields.io/github/license/aaronrussell/omni?color=informational)
![Build Status](https://img.shields.io/github/actions/workflow/status/aaronrussell/omni/elixir.yml?branch=main)

**Universal Elixir client for LLM APIs.**
Streaming text generation, tool use, and structured output.

## Features

- **Multi-provider** — supports many LLM providers out of the box (see table below)
- **Streaming-first** — all requests stream by default; `generate_text` is built on `stream_text`
- **Tool use** — define tools with schemas and handlers; the loop auto-executes and feeds results back
- **Structured output** — JSON Schema validation with constrained decoding and automatic retries
- **Extensible** — add custom providers by implementing a behaviour

## Installation

Add Omni to your dependencies:

```elixir
def deps do
  [
    {:omni, "~> 1.2"}
  ]
end
```

Each built-in provider reads its API key from a standard environment variable
by default — if your keys are set, no configuration is needed:

| Provider | Environment variable |
| --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` |
| Google | `GEMINI_API_KEY` |
| Groq | `GROQ_API_KEY` |
| Moonshot AI | `MOONSHOT_API_KEY` |
| Ollama Cloud | `OLLAMA_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| OpenCode | `OPENCODE_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| Z.ai | `ZAI_API_KEY` |

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

For multi-turn conversations, build a context with a system prompt and messages:

```elixir
context = Omni.context(
  system: "You are a helpful assistant.",
  messages: [
    Omni.message(role: :user, content: "What is Elixir?"),
    Omni.message(role: :assistant, content: "Elixir is a functional programming language..."),
    Omni.message(role: :user, content: "How does it handle concurrency?")
  ]
)

{:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, context)
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

For simple cases where you just need the text chunks:

```elixir
stream
|> Omni.StreamingResponse.text_stream()
|> Enum.each(&IO.write/1)
```

### Structured output

Pass a schema via the `:output` option to get validated, decoded output:

```elixir
schema = Omni.Schema.object(%{
  name: Omni.Schema.string(description: "The capital city"),
  population: Omni.Schema.integer(description: "Approximate population")
}, required: [:name, :population])

{:ok, response} =
  Omni.generate_text(
    {:anthropic, "claude-sonnet-4-5-20250514"},
    "What is the capital of France?",
    output: schema
  )

response.output
#=> %{name: "Paris", population: 2161000}
```

### Tool use

Define tools with schemas and handlers — the loop automatically executes tool uses and feeds results back to the model:

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

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/omni).

## License

This package is open source and released under the [Apache-2 License](https://github.com/aaronrussell/omni/blob/master/LICENSE).

© Copyright 2024-2026 [Push Code Ltd](https://www.pushcode.com/).
