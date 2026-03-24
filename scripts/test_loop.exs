alias Omni.{Context, Message, StreamingResponse}

Omni.Provider.load(openrouter: Omni.Providers.OpenRouter)

time_map = %{
  "London" => "17:28",
  "New York" => "12:28",
}

weather_map = %{
  "London" => "Cloudy with light drizzle, mild temperatures around 8°C.",
  "New York" => "Partly sunny, cold and breezy, highs near 2°C.",
}

time_tool =
  Omni.tool(
    name: "get_time",
    description: "Gets the current time for a city",
    input_schema: %{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    },
    handler: fn input -> Map.get(time_map, input[:city]) end
  )

weather_tool =
  Omni.tool(
    name: "get_weather",
    description: "Gets the current weather for a city",
    input_schema: %{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    },
    handler: fn input -> Map.get(weather_map, input[:city]) end
  )

context =
  Context.new(
    messages: [Message.new("What's the current time and weather in London and New York?")],
    tools: [time_tool, weather_tool]
  )

# Omni.stream_text({:anthropic, "claude-haiku-4-5"}, context)
# Omni.stream_text({:google, "gemini-3-flash-preview"}, context)
# Omni.stream_text({:openai, "gpt-5-mini"}, context)
# Omni.stream_text({:openrouter, "openai/gpt-5-mini"}, context)

{:ok, resp} =
  Omni.stream_text({:openrouter, "openai/gpt-5-mini"}, context)
  |> then(fn {:ok, sr} ->
    sr
    |> StreamingResponse.on(:text_end, fn e -> dbg(e, label: "text") end)
    |> StreamingResponse.on(:tool_use_end, fn e -> dbg(e, label: "tool_use") end)
    |> StreamingResponse.on(:tool_result, fn e -> dbg(e, label: "tool_result") end)
    |> StreamingResponse.on(:done, fn _ -> IO.puts("DONE") end)
    |> StreamingResponse.complete()
  end)

dbg(resp.stop_reason, label: "stop_reason")
dbg(length(resp.messages), label: "message_count")
dbg(resp.usage, label: "usage")
