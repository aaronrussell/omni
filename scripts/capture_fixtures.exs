alias Omni.Test.Capture

# Load additional providers
Omni.Provider.load([:opencode, :openrouter])

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
          "description" => "The city, e.g. San Francisco"
        }
      },
      "required" => ["location"]
    }
  )

prompts = %{
  :text => "Write a haiku about why the sky is blue.",
  :thinking => "How many R's are in strawberry?",
  :tool_use => "Get the current weather in London, UK"
}

models = %{
  #:anthropic => "claude-haiku-4-5",
  #:openai => "gpt-5-mini",
  #:google => "gemini-3-flash-preview",
  #:openrouter => "openai/gpt-4o-mini",
  #:opencode => "kimi-k2.5"
}

for provider <- Map.keys(models) do
  {:ok, model} = Omni.get_model(provider, models[provider])

  IO.puts("Capturing #{provider}_text...")
  Capture.record(
    model,
    Omni.context(prompts[:text]),
    "#{fixture_dir}/#{provider}_text.sse",
    thinking: false
  )

  IO.puts("Capturing #{provider}_thinking...")
  Capture.record(
    model,
    Omni.context(prompts[:thinking]),
    "#{fixture_dir}/#{provider}_thinking.sse",
    thinking: :low
  )

  IO.puts("Capturing #{provider}_tool_use...")
  Capture.record(
    model,
    Omni.context(
      messages: [Omni.message("What is the weather in London?")],
      tools: [weather_tool]
    ),
    "#{fixture_dir}/#{provider}_tool_use.sse",
    thinking: false
  )
end

IO.puts("Done! All fixtures captured.")
