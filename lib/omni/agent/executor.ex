defmodule Omni.Agent.Executor do
  @moduledoc false

  alias Omni.Tool

  @doc """
  Starts a linked executor process that runs tool executions in parallel.

  Sends `{ref, {:tools_executed, results}}` back to the parent on completion.
  Tool.Runner handles all per-tool failures internally (exceptions, timeouts,
  hallucinated names), so this process should not crash under normal operation.
  """
  def start_link(parent, ref, tool_uses, tool_map, timeout) do
    Task.start_link(fn ->
      results = Tool.Runner.run(tool_uses, tool_map, timeout)
      send(parent, {ref, {:tools_executed, results}})
    end)
  end
end
