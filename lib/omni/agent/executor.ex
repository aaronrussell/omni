defmodule Omni.Agent.Executor do
  @moduledoc false

  alias Omni.Tool

  @doc """
  Starts a linked executor process that runs tool executions in parallel.

  Sends ref-tagged messages back to the parent:

    - `{ref, {:tools_executed, results}}` — successful completion
    - `{ref, {:executor_error, reason}}` — unexpected failure
  """
  def start_link(parent, ref, tool_uses, tool_map, timeout) do
    Task.start_link(fn -> run(parent, ref, tool_uses, tool_map, timeout) end)
  end

  defp run(parent, ref, tool_uses, tool_map, timeout) do
    try do
      results = Tool.Runner.run(tool_uses, tool_map, timeout)
      send(parent, {ref, {:tools_executed, results}})
    rescue
      e -> send(parent, {ref, {:executor_error, Exception.message(e)}})
    end
  end
end
