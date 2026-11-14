defmodule Omni.Content.ToolResult do
  @moduledoc """
  A tool result content block: the output of one tool use.

  It goes in a user message, answering an `Omni.Content.ToolUse` in the
  assistant message before it. The tool loop builds these for you; build
  them yourself with `Omni.tool_result/1` when you run tools by hand (see
  [Running tools yourself](text-generation.md#running-tools-yourself)).

  ## Struct fields

  - `:tool_use_id` - the `:id` of the tool use this answers
  - `:name` - the tool's name
  - `:content` - the result, as `Omni.Content.Text` and
    `Omni.Content.Attachment` blocks. Only some providers take images in a
    tool result
  - `:is_error` - `true` when the tool failed, so the model knows the
    content describes an error
  """

  alias Omni.Content.{Attachment, Text}

  @enforce_keys [:tool_use_id, :name]
  defstruct [:tool_use_id, :name, :content, is_error: false]

  @typedoc "Allowed content types within a tool result."
  @type content :: Text.t() | Attachment.t()

  @typedoc "The output of a tool use, linked to it by id."
  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          name: String.t(),
          content: [content()],
          is_error: boolean()
        }

  @doc """
  Creates a new tool result content block from a keyword list or map.

  String content is wrapped in an `Omni.Content.Text` block, and so is each
  string in a content list. Missing content becomes `[]`.

  ```elixir
  ToolResult.new(tool_use_id: tool_use.id, name: tool_use.name, content: "72°F and sunny")
  ```
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
