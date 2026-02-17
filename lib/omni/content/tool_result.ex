defmodule Omni.Content.ToolResult do
  @moduledoc """
  A tool result content block representing the output of a tool invocation.

  Appears in user messages to provide the result of a preceding
  `Omni.Content.ToolUse`. The `tool_use_id` links back to the originating
  tool use block. Content is restricted to `Text` and `Thinking` blocks.

  String content is automatically normalized to a single `Text` block, and
  `nil` content is normalized to an empty list.
  """

  alias Omni.Content.{Text, Thinking}

  defstruct [:tool_use_id, :name, :content, is_error: false]

  @typedoc "Allowed content types within a tool result."
  @type content :: Text.t() | Thinking.t()

  @typedoc "A tool result content block."
  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          name: String.t(),
          content: [content()],
          is_error: boolean()
        }

  @doc """
  Creates a new tool result content block from a keyword list or map.

  String content is wrapped in a `Text` block. `nil` content becomes `[]`.
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.update(:content, [], fn
      content when is_binary(content) -> [Text.new(content)]
      content -> content
    end)
    |> then(&struct!(__MODULE__, &1))
  end
end
