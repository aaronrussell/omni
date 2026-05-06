defmodule Omni.ToolTest do
  use ExUnit.Case, async: true

  alias Omni.Tool

  defmodule StatelessTool do
    use Omni.Tool, name: "add_one", description: "Adds one to x"

    def schema, do: Omni.Schema.object(%{x: Omni.Schema.integer()}, required: [:x])

    def call(input), do: input.x + 1
  end

  defmodule StatefulTool do
    use Omni.Tool, name: "multiply", description: "Multiplies x by a factor"

    def schema, do: Omni.Schema.object(%{x: Omni.Schema.number()}, required: [:x])

    def init(factor), do: factor

    def call(input, factor), do: input.x * factor
  end

  defmodule FailingTool do
    use Omni.Tool, name: "fail", description: "Always fails"

    def schema, do: Omni.Schema.object(%{})

    def call(_input), do: raise("boom")
  end

  defmodule CallbackOnlyTool do
    use Omni.Tool

    @impl Omni.Tool
    def name, do: "callback_only"

    @impl Omni.Tool
    def description, do: "Defined via callbacks"

    @impl Omni.Tool
    def schema, do: Omni.Schema.object(%{x: Omni.Schema.integer()}, required: [:x])

    @impl Omni.Tool
    def call(input), do: input.x
  end

  defmodule DynamicDescriptionTool do
    use Omni.Tool, name: "dynamic", description: "Base description"

    @impl Omni.Tool
    def schema, do: Omni.Schema.object(%{x: Omni.Schema.integer()}, required: [:x])

    @impl Omni.Tool
    def init(opts), do: opts

    @impl Omni.Tool
    def description(opts) do
      base = description()

      case opts[:extra] do
        nil -> base
        extra -> base <> "\n\n" <> extra
      end
    end

    @impl Omni.Tool
    def call(input, _opts), do: input.x
  end

  defmodule DescriptionOnlyArity1Tool do
    use Omni.Tool, name: "desc_only_1"

    @impl Omni.Tool
    def schema, do: Omni.Schema.object(%{x: Omni.Schema.integer()}, required: [:x])

    @impl Omni.Tool
    def description(label), do: "Tool labelled: #{label}"

    @impl Omni.Tool
    def call(input), do: input.x
  end

  defmodule DynamicSchemaTool do
    use Omni.Tool, name: "dyn_schema", description: "Schema depends on init"

    @impl Omni.Tool
    def init(opts), do: opts

    @impl Omni.Tool
    def schema(opts) do
      fields = Keyword.get(opts, :fields, [:x])
      properties = Map.new(fields, fn f -> {f, Omni.Schema.integer()} end)
      Omni.Schema.object(properties, required: fields)
    end

    @impl Omni.Tool
    def call(_input, _opts), do: :ok
  end

  defmodule SchemaOnlyArity1Tool do
    use Omni.Tool, name: "schema_only_1", description: "Schema only via /1"

    @impl Omni.Tool
    def schema(modes) do
      Omni.Schema.object(
        %{mode: Omni.Schema.string(enum: modes)},
        required: [:mode]
      )
    end

    @impl Omni.Tool
    def call(input, _modes), do: input.mode
  end

  defmodule MissingDescriptionTool do
    use Omni.Tool, name: "missing_desc"

    @impl Omni.Tool
    def schema, do: Omni.Schema.object(%{})

    @impl Omni.Tool
    def call(_input), do: :ok
  end

  defmodule MissingSchemaTool do
    use Omni.Tool, name: "missing_schema", description: "no schema"

    @impl Omni.Tool
    def call(_input), do: :ok
  end

  describe "new/1" do
    test "creates from keyword list" do
      tool = Tool.new(name: "test", description: "A test tool", input_schema: %{})

      assert %Tool{name: "test", description: "A test tool", input_schema: %{}, handler: nil} =
               tool
    end

    test "creates from map" do
      tool = Tool.new(%{name: "test", description: "desc", input_schema: %{}})
      assert tool.name == "test"
    end

    test "handler defaults to nil" do
      tool = Tool.new(name: "t", description: "d", input_schema: %{})
      assert tool.handler == nil
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Tool.new(name: "t", description: "d", bogus: true)
      end
    end
  end

  describe "stateless tool behaviour" do
    test "new/0 builds a tool struct" do
      tool = StatelessTool.new()

      assert %Tool{name: "add_one", description: "Adds one to x"} = tool

      assert tool.input_schema == %{
               type: "object",
               properties: %{x: %{type: "integer"}},
               required: [:x]
             }

      assert is_function(tool.handler, 1)
    end

    test "handler executes call/1" do
      # Direct handler calls bypass validation/casting — caller provides keys
      tool = StatelessTool.new()
      assert tool.handler.(%{x: 5}) == 6
    end
  end

  describe "stateful tool behaviour" do
    test "new/1 passes params through init/1" do
      tool = StatefulTool.new(3)

      assert %Tool{name: "multiply", description: "Multiplies x by a factor"} = tool
      assert is_function(tool.handler, 1)
    end

    test "handler uses initialized state" do
      # Direct handler calls bypass validation/casting — caller provides keys
      tool = StatefulTool.new(10)
      assert tool.handler.(%{x: 5}) == 50
    end

    test "new/0 passes nil to init" do
      tool = StatefulTool.new()
      # factor is nil, so nil * 5 raises
      assert_raise ArithmeticError, fn ->
        tool.handler.(%{x: 5})
      end
    end
  end

  describe "callback-only tool" do
    test "new/0 builds a tool struct from callback implementations" do
      tool = CallbackOnlyTool.new()

      assert %Tool{name: "callback_only", description: "Defined via callbacks"} = tool
      assert is_function(tool.handler, 1)
    end

    test "handler executes call/1" do
      tool = CallbackOnlyTool.new()
      assert tool.handler.(%{x: 42}) == 42
    end
  end

  describe "dynamic description" do
    test "default description/1 delegates to description/0" do
      tool = StatelessTool.new()
      assert tool.description == "Adds one to x"
    end

    test "description/1 can incorporate init state" do
      tool = DynamicDescriptionTool.new(extra: "Only recent results.")
      assert tool.description == "Base description\n\nOnly recent results."
    end

    test "description/1 falls back to base when state has no extra" do
      tool = DynamicDescriptionTool.new([])
      assert tool.description == "Base description"
    end

    test "description/1 can be implemented alone (no description/0, no description: option)" do
      tool = DescriptionOnlyArity1Tool.new("widget")
      assert tool.description == "Tool labelled: widget"
    end

    test "raises a helpful error when neither description/0 nor description/1 is implemented" do
      assert_raise RuntimeError, ~r/must implement description\/0 or description\/1/, fn ->
        MissingDescriptionTool.new()
      end
    end
  end

  describe "dynamic schema" do
    test "default schema/1 delegates to schema/0" do
      tool = StatelessTool.new()

      assert tool.input_schema == %{
               type: "object",
               properties: %{x: %{type: "integer"}},
               required: [:x]
             }
    end

    test "schema/1 can incorporate init state" do
      tool = DynamicSchemaTool.new(fields: [:a, :b])

      assert tool.input_schema == %{
               type: "object",
               properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
               required: [:a, :b]
             }
    end

    test "schema/1 can be implemented alone (no schema/0)" do
      tool = SchemaOnlyArity1Tool.new(["focus", "casual"])

      assert tool.input_schema == %{
               type: "object",
               properties: %{mode: %{type: "string", enum: ["focus", "casual"]}},
               required: [:mode]
             }
    end

    test "raises a helpful error when neither schema/0 nor schema/1 is implemented" do
      assert_raise RuntimeError, ~r/must implement schema\/0 or schema\/1/, fn ->
        MissingSchemaTool.new()
      end
    end
  end

  describe "execute/2" do
    test "returns {:ok, result} on success" do
      tool = StatelessTool.new()
      assert {:ok, 6} = Tool.execute(tool, %{"x" => 5})
    end

    test "casts string-keyed input to atom keys via schema" do
      tool = StatelessTool.new()
      # Handler uses input.x (atom key) — Peri casts "x" => :x
      assert {:ok, 11} = Tool.execute(tool, %{"x" => 10})
    end

    test "returns {:error, exception} on raise" do
      tool = FailingTool.new()
      assert {:error, %RuntimeError{message: "boom"}} = Tool.execute(tool, %{})
    end

    test "validates input against schema" do
      tool = StatelessTool.new()
      assert {:error, _errors} = Tool.execute(tool, %{"x" => "not_an_integer"})
    end

    test "returns validation error for missing required field" do
      tool = StatelessTool.new()
      assert {:error, _errors} = Tool.execute(tool, %{})
    end

    test "skips validation when input_schema is nil" do
      handler = fn input -> input["x"] end
      tool = Tool.new(name: "t", description: "d", input_schema: nil, handler: handler)
      assert {:ok, 42} = Tool.execute(tool, %{"x" => 42})
    end

    test "raises FunctionClauseError when handler is nil" do
      tool = Tool.new(name: "t", description: "d", input_schema: %{})

      assert_raise FunctionClauseError, fn ->
        Tool.execute(tool, %{})
      end
    end
  end
end
