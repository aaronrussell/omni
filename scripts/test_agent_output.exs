defmodule MyAgent do
  use Omni.Agent

  def handle_stop(_response, state) do
    if state.step < 3 do
      {:continue, "And another", state}
    else
      {:stop, state}
    end
  end
end

{:ok, pid} = Omni.Agent.start_link(MyAgent, model: {:anthropic, "claude-haiku-4-5"})

schema = Omni.Schema.object(%{
  name: Omni.Schema.string(description: "Full character name"),
  role: Omni.Schema.string(description: "Role or profession"),
  traits: Omni.Schema.string(description: "Character traits (max 50 words)"),
}, required: [:name, :role, :traits])

:ok = Omni.Agent.prompt(pid, "Create a character for a Roman-themed comedy movie.", output: schema)

defmodule Loop do
  def listen(pid) do
    receive do
    {:agent, ^pid, :error, error} ->
			dbg error

	  {:agent, ^pid, :done, response} ->
			dbg response.output

		{:agent, ^pid, :turn, response} ->
      dbg response.output
			listen(pid)

		{:agent, ^pid, event_type, _event} ->
		  IO.write(inspect(event_type))
		  listen(pid)
    end
  end
end

Loop.listen(pid)
GenServer.stop(pid, :normal)
IO.puts "DONE"
