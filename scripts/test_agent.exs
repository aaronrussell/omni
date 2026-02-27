{:ok, pid} = Omni.Agent.start_link(model: {:anthropic, "claude-haiku-4-5"})

weather_map = %{
  "London" => "Cloudy with light drizzle, mild temperatures around 8°C.",
  "New York" => "Partly sunny, cold and breezy, highs near 2°C.",
}

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

:ok = Omni.Agent.add_tools(pid, [weather_tool])

:ok = Omni.Agent.prompt(pid, "What is the weather like in London?")

defmodule Loop do
  def listen(pid) do
    receive do
	  {:agent, ^pid, :done, response} ->
			IO.puts "==== DONE ===="
			dbg response

		{:agent, ^pid, event_type, _event} ->
		  dbg event_type
			listen(pid)
    end
  end
end

Loop.listen(pid)
GenServer.stop(pid, :normal)
IO.puts "...end"
