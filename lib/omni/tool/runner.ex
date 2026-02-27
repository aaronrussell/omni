defmodule Omni.Tool.Runner do
  @moduledoc """
  Runs tool use blocks against a map of available tools.

  Takes `ToolUse` content blocks from an assistant message, executes the
  corresponding tools in parallel, and returns `ToolResult` content blocks
  ready to be placed in a user message. Handles hallucinated tool names,
  execution errors, and timeouts.

  This is the bridge between content blocks and `Tool.execute/2` — used by
  both `Omni.Loop` and `Omni.Agent.Executor`.
  """

  alias Omni.Tool
  alias Omni.Content.{ToolResult, ToolUse}

  @doc """
  Executes tool uses in parallel, returning results in input order.

  Each tool use is looked up by name in the `tool_map`. Missing tools
  (hallucinated names) produce error results. Tools that raise or exceed
  the timeout also produce error results.
  """
  @spec run([ToolUse.t()], %{String.t() => Tool.t()}, timeout()) :: [ToolResult.t()]
  def run(tool_uses, tool_map, timeout \\ 5_000) do
    tasks =
      Enum.map(tool_uses, fn tool_use ->
        Task.async(fn -> run_one(tool_use, tool_map) end)
      end)

    tasks
    |> Task.yield_many(timeout)
    |> Enum.zip(tool_uses)
    |> Enum.map(fn
      {{_task, {:ok, result}}, _tool_use} ->
        result

      {{_task, {:exit, reason}}, tool_use} ->
        error_result(tool_use, "Tool execution failed: #{inspect(reason)}")

      {{task, nil}, tool_use} ->
        Task.shutdown(task, :brutal_kill)
        error_result(tool_use, "Tool execution timed out")
    end)
  end

  defp run_one(tool_use, tool_map) do
    case Map.get(tool_map, tool_use.name) do
      nil ->
        error_result(tool_use, "Tool not found: #{tool_use.name}")

      %Tool{} = tool ->
        case Tool.execute(tool, tool_use.input) do
          {:ok, result} ->
            ToolResult.new(
              tool_use_id: tool_use.id,
              name: tool_use.name,
              content: format_result(result)
            )

          {:error, error} ->
            error_result(tool_use, format_result(error))
        end
    end
  end

  defp error_result(tool_use, message) do
    ToolResult.new(
      tool_use_id: tool_use.id,
      name: tool_use.name,
      content: message,
      is_error: true
    )
  end

  defp format_result(value) when is_binary(value), do: value
  defp format_result(value), do: inspect(value)
end
