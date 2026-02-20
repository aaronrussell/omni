alias Omni.Test.Capture

# Load OpenRouter (not in default providers)
Omni.Provider.load([:openrouter])

fixture_dir = "test/support/fixtures/sse"

# Shared tool
weather_tool =
  Omni.tool(
    name: "get_weather",
    description: "Get the current weather in a given location",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "location" => %{
          "type" => "string",
          "description" => "The city and state, e.g. San Francisco, CA"
        }
      },
      "required" => ["location"]
    }
  )

# ── Anthropic ──────────────────────────────────────────────────────────────────

{:ok, anthropic_text_model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
{:ok, anthropic_thinking_model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
{:ok, anthropic_tool_model} = Omni.get_model(:anthropic, "claude-haiku-4-5")

IO.puts("Capturing anthropic_text...")

Capture.record(
  anthropic_text_model,
  Omni.context("Write a haiku about why the sky is blue."),
  "#{fixture_dir}/anthropic_text.sse"
)

IO.puts("Capturing anthropic_thinking...")

Capture.record(
  anthropic_thinking_model,
  Omni.context("How many R's are in strawberry?"),
  "#{fixture_dir}/anthropic_thinking.sse",
  thinking: :low
)

IO.puts("Capturing anthropic_tool_use...")

Capture.record(
  anthropic_tool_model,
  Omni.context(messages: [Omni.message("What is the weather in London?")], tools: [weather_tool]),
  "#{fixture_dir}/anthropic_tool_use.sse"
)

# ── OpenAI (Responses API) ────────────────────────────────────────────────────

{:ok, openai_text_model} = Omni.get_model(:openai, "gpt-4.1-mini")
{:ok, openai_thinking_model} = Omni.get_model(:openai, "gpt-5-mini")
{:ok, openai_tool_model} = Omni.get_model(:openai, "gpt-5-mini")

IO.puts("Capturing openai_responses_text...")

Capture.record(
  openai_text_model,
  Omni.context("Write a haiku about why the sky is blue."),
  "#{fixture_dir}/openai_responses_text.sse"
)

IO.puts("Capturing openai_responses_thinking...")

Capture.record(
  openai_thinking_model,
  Omni.context("How many R's are in strawberry?"),
  "#{fixture_dir}/openai_responses_thinking.sse",
  thinking: :low
)

IO.puts("Capturing openai_responses_tool_use...")

Capture.record(
  openai_tool_model,
  Omni.context(messages: [Omni.message("What is the weather in London?")], tools: [weather_tool]),
  "#{fixture_dir}/openai_responses_tool_use.sse"
)

# ── Google Gemini ──────────────────────────────────────────────────────────────

{:ok, google_text_model} = Omni.get_model(:google, "gemini-2.0-flash-lite")
{:ok, google_thinking_model} = Omni.get_model(:google, "gemini-2.5-flash")
{:ok, google_tool_model} = Omni.get_model(:google, "gemini-2.5-flash")

IO.puts("Capturing google_text...")

Capture.record(
  google_text_model,
  Omni.context("Write a haiku about why the sky is blue."),
  "#{fixture_dir}/google_text.sse"
)

IO.puts("Capturing google_thinking...")

Capture.record(
  google_thinking_model,
  Omni.context("How many R's are in strawberry?"),
  "#{fixture_dir}/google_thinking.sse",
  thinking: [budget: 1024]
)

IO.puts("Capturing google_tool_use...")

Capture.record(
  google_tool_model,
  Omni.context(messages: [Omni.message("What is the weather in London?")], tools: [weather_tool]),
  "#{fixture_dir}/google_tool_use.sse"
)

# ── OpenRouter (Completions API) ──────────────────────────────────────────────

{:ok, openrouter_text_model} = Omni.get_model(:openrouter, "openai/gpt-4.1-mini")
{:ok, openrouter_thinking_model} = Omni.get_model(:openrouter, "openai/gpt-5-mini")
{:ok, openrouter_tool_model} = Omni.get_model(:openrouter, "openai/gpt-5-mini")

IO.puts("Capturing openrouter_text...")

Capture.record(
  openrouter_text_model,
  Omni.context("Write a haiku about why the sky is blue."),
  "#{fixture_dir}/openrouter_text.sse"
)

IO.puts("Capturing openrouter_thinking...")

Capture.record(
  openrouter_thinking_model,
  Omni.context("How many R's are in strawberry?"),
  "#{fixture_dir}/openrouter_thinking.sse",
  thinking: :low
)

IO.puts("Capturing openrouter_tool_use...")

Capture.record(
  openrouter_tool_model,
  Omni.context(messages: [Omni.message("What is the weather in London?")], tools: [weather_tool]),
  "#{fixture_dir}/openrouter_tool_use.sse"
)

IO.puts("Done! All fixtures captured.")
