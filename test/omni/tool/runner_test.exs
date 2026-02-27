defmodule Omni.Tool.RunnerTest do
  use ExUnit.Case, async: true

  alias Omni.Tool.Runner
  alias Omni.Content.{ToolResult, ToolUse}

  defmodule AddOne do
    use Omni.Tool, name: "add_one", description: "Adds one to x"

    def schema, do: Omni.Schema.object(%{x: Omni.Schema.integer()}, required: [:x])

    def call(input), do: input.x + 1
  end

  defmodule Multiply do
    use Omni.Tool, name: "multiply", description: "Multiplies x by a factor"

    def schema, do: Omni.Schema.object(%{x: Omni.Schema.number()}, required: [:x])

    def init(factor), do: factor

    def call(input, factor), do: input.x * factor
  end

  defmodule Failing do
    use Omni.Tool, name: "fail", description: "Always fails"

    def schema, do: Omni.Schema.object(%{})

    def call(_input), do: raise("boom")
  end

  defmodule Slow do
    use Omni.Tool, name: "slow", description: "Sleeps forever"

    def schema, do: Omni.Schema.object(%{})

    def call(_input), do: Process.sleep(:infinity)
  end

  defp make_tool_use(id, name, input) do
    ToolUse.new(id: id, name: name, input: input)
  end

  defp make_tool_map(tools), do: Map.new(tools, &{&1.name, &1})

  describe "run/3" do
    test "parallel execution of multiple tools, results in order" do
      tool_map = make_tool_map([AddOne.new(), Multiply.new(2)])

      tool_uses = [
        make_tool_use("tu_1", "add_one", %{"x" => 5}),
        make_tool_use("tu_2", "multiply", %{"x" => 3})
      ]

      results = Runner.run(tool_uses, tool_map)

      assert [%ToolResult{} = r1, %ToolResult{} = r2] = results

      assert r1.tool_use_id == "tu_1"
      assert r1.name == "add_one"
      assert r1.is_error == false

      assert r2.tool_use_id == "tu_2"
      assert r2.name == "multiply"
      assert r2.is_error == false
    end

    test "hallucinated tool name produces error result, others succeed" do
      tool_map = make_tool_map([AddOne.new()])

      tool_uses = [
        make_tool_use("tu_1", "nonexistent", %{}),
        make_tool_use("tu_2", "add_one", %{"x" => 1})
      ]

      results = Runner.run(tool_uses, tool_map)

      assert [
               %ToolResult{is_error: true, name: "nonexistent"} = r1,
               %ToolResult{is_error: false} = r2
             ] = results

      assert [%Omni.Content.Text{text: "Tool not found: nonexistent"}] = r1.content
      assert r2.name == "add_one"
    end

    test "tool that raises produces error result, others succeed" do
      tool_map = make_tool_map([Failing.new(), AddOne.new()])

      tool_uses = [
        make_tool_use("tu_1", "fail", %{}),
        make_tool_use("tu_2", "add_one", %{"x" => 10})
      ]

      results = Runner.run(tool_uses, tool_map)

      assert [%ToolResult{is_error: true}, %ToolResult{is_error: false}] = results
    end

    test "tool that exceeds timeout produces error result, others succeed" do
      tool_map = make_tool_map([Slow.new(), AddOne.new()])

      tool_uses = [
        make_tool_use("tu_1", "slow", %{}),
        make_tool_use("tu_2", "add_one", %{"x" => 1})
      ]

      results = Runner.run(tool_uses, tool_map, 100)

      assert [%ToolResult{is_error: true} = r1, %ToolResult{is_error: false}] = results
      assert [%Omni.Content.Text{text: "Tool execution timed out"}] = r1.content
    end

    test "empty tool_uses list returns empty list" do
      assert Runner.run([], %{}) == []
    end
  end
end
