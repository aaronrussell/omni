defmodule Omni.Content.ToolResult do
  @moduledoc """
  A tool result content block representing the output of a tool invocation.

  Appears in user messages to provide the result of a preceding
  `Omni.Content.ToolUse`. The `tool_use_id` links back to the originating
  tool use block. Content is restricted to `Text` and `Attachment` blocks
  (image attachments are only supported by some providers).
  """

  alias Omni.Content.{Attachment, Text}

  @enforce_keys [:tool_use_id, :name]
  defstruct [:tool_use_id, :name, :content, is_error: false]

  @typedoc "Allowed content types within a tool result."
  @type content :: Text.t() | Attachment.t()

  @typedoc "Output of a tool invocation, linked to its originating `ToolUse` by ID."
  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          name: String.t(),
          content: [content()],
          is_error: boolean()
        }

  @doc """
  Creates a new tool result content block from a keyword list or map.

  String content is wrapped in a `Text` block, and so is each string in a
  content list. Missing content becomes `[]`.

      ToolResult.new(tool_use_id: tool_use.id, name: tool_use.name, content: "72°F and sunny")
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.update(:content, [], &content/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp content(text) when is_binary(text), do: [Text.new(text)]
  defp content(blocks) when is_list(blocks), do: Enum.map(blocks, &block/1)
  defp content(other), do: other

  defp block(text) when is_binary(text), do: Text.new(text)
  defp block(block), do: block
end
