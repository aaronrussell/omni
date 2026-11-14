defmodule Omni.Tool.Runner do
  @moduledoc """
  Runs tool uses in parallel and returns their tool results.

  The tool loop uses this to run the tools the model asks for. Use it
  yourself when you take over the loop, with `max_steps: 1`, and want the
  same validation, timeouts and error handling (see
  [Running tools yourself](text-generation.md#running-tools-yourself)).

  ```elixir
  {:ok, response} = Omni.generate_text(model, context, max_steps: 1)

  tool_uses = Enum.filter(response.message.content, &match?(%Omni.Content.ToolUse{}, &1))
  tools = Map.new(context.tools, &{&1.name, &1})

  results = Omni.Tool.Runner.run(tool_uses, tools)

  context =
    context
    |> Omni.Context.push(response)
    |> Omni.Context.push(Omni.message(role: :user, content: results))
  ```
  """

  alias Omni.Tool
  alias Omni.Content.{ToolResult, ToolUse}

  @doc """
  Runs tool uses in parallel, returning one result for each, in order.

  `tool_map` maps each tool's name to its `Omni.Tool`. A result's content
  is what the handler returned: a string as it is, anything else as JSON.

  A tool use never fails the call. A name with no tool in the map, input
  that fails the schema, a handler that raises and a tool that outruns the
  timeout each give a result with `is_error: true` and a message the model
  can read.

  `timeout` is in milliseconds and applies to each tool (default `5_000`;
  the tool loop passes its `:tool_timeout`).
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

          {:error, error} when is_binary(error) ->
            error_result(tool_use, error)

          {:error, error} ->
            error_result(tool_use, inspect(error))
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
