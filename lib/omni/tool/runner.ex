defmodule Omni.Tool.Runner do
  @moduledoc """
  Executes tool use blocks in parallel and returns tool result blocks.

  Takes `ToolUse` content blocks from an assistant message, runs the
  corresponding tools concurrently, and returns `ToolResult` content blocks
  ready to be placed in a user message.

  Omni's generation loop uses this internally, but it's also useful
  when you handle tool execution yourself — for example, with schema-only
  tools where the loop breaks and hands `ToolUse` blocks back to you:

      # Schema-only tool — loop breaks, response contains ToolUse blocks
      tool_uses = Enum.filter(response.message.content, &match?(%ToolUse{}, &1))

      # Build a tool map and execute
      tool_map = %{"search" => search_tool, "fetch" => fetch_tool}
      results = Tool.Runner.run(tool_uses, tool_map)

      # Place results in the next user message
      message = Omni.message(role: :user, content: results)
  """

  alias Omni.Tool
  alias Omni.Content.{ToolResult, ToolUse}

  @doc """
  Executes tool uses in parallel, returning results in input order.

  `tool_map` is a `%{name => %Tool{}}` map keyed by tool name strings. Each
  tool use is looked up by name — missing tools (hallucinated names), tools
  that raise, and tools that exceed the timeout all produce error results
  with `is_error: true`. Every input `ToolUse` produces exactly one output
  `ToolResult`, always in the same order.

  The default timeout is 5000ms per tool.
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

          {:error, %{__exception__: true} = error} ->
            error_result(tool_use, Exception.message(error))

          {:error, error} ->
            error_result(tool_use, Omni.Schema.format_errors(error))
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

  defp format_result(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value)
  end
end
