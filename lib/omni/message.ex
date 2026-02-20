defmodule Omni.Message do
  @moduledoc """
  A message in a conversation.

  Messages have a `:user` or `:assistant` role and carry a list of content
  blocks. There is no `:tool` role — tool results are `Content.ToolResult`
  blocks inside user messages.

  A UTC timestamp is automatically assigned at construction time unless one
  is explicitly provided (including explicit `nil`).
  """

  alias Omni.Content.{Text, Thinking, Attachment, ToolUse, ToolResult}

  @enforce_keys [:role]
  defstruct [:role, content: [], timestamp: nil, private: %{}]

  @typedoc "Any content block that can appear in a message."
  @type content :: Text.t() | Thinking.t() | Attachment.t() | ToolUse.t() | ToolResult.t()

  @typedoc "A conversation message."
  @type t :: %__MODULE__{
          role: :user | :assistant,
          content: [content()],
          timestamp: DateTime.t(),
          private: map()
        }

  @doc """
  Creates a new message from a string, keyword list, or map.

  A string is treated as a user message with that text as content. String
  content is wrapped in a `Text` block. A timestamp is auto-assigned via
  `DateTime.utc_now/0` unless explicitly set.
  """
  @spec new(String.t() | Enumerable.t()) :: t()
  def new(text) when is_binary(text), do: new(role: :user, content: text)

  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.put_new_lazy(:timestamp, &now/0)
    |> Map.update(:content, [], fn
      content when is_binary(content) -> [Text.new(content)]
      content -> content
    end)
    |> then(&struct!(__MODULE__, &1))
  end

  defp now, do: DateTime.utc_now()
end
