defmodule Omni.Message do
  @moduledoc """
  A message in a conversation.

  Messages have a `:user` or `:assistant` role and carry a list of content
  blocks. There is no `:tool` role — tool results are `Content.ToolResult`
  blocks inside user messages.

  A UTC timestamp is assigned at construction unless explicitly set.

  Assistant messages Omni produces carry an `:origin`: the model that wrote
  them and the dialect it spoke. Thinking and signatures only go back to the
  provider and dialect that produced them; a message from anywhere else, or
  with no origin, is sent without them. See `t:origin/0`.
  """

  alias Omni.Model
  alias Omni.Content.{Text, Thinking, Attachment, ToolUse, ToolResult}

  @enforce_keys [:role]
  defstruct [:role, content: [], timestamp: nil, origin: nil, private: %{}]

  @typedoc "Any content block that can appear in a message."
  @type content :: Text.t() | Thinking.t() | Attachment.t() | ToolUse.t() | ToolResult.t()

  @typedoc "The model that wrote an assistant message, and the dialect it spoke."
  @type origin :: %{model: {atom(), String.t()}, dialect: module()}

  @typedoc "A conversation message."
  @type t :: %__MODULE__{
          role: :user | :assistant,
          content: [content()],
          timestamp: DateTime.t(),
          origin: origin() | nil,
          private: map()
        }

  @doc """
  Creates a new message from a string, keyword list, or map.

  A string is treated as a user message with that text as content. String
  content is wrapped in a `Text` block. A timestamp is auto-assigned via
  `DateTime.utc_now/0` unless explicitly set.

  `:origin` takes the `%Model{}` that wrote the message, recorded as its
  reference and dialect, or an origin map as is:

      Message.new(role: :assistant, content: "Hi", origin: model)
  """
  @spec new(Enumerable.t() | String.t() | t()) :: t()
  def new(%__MODULE__{} = message), do: message

  def new(text) when is_binary(text), do: new(role: :user, content: text)

  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.put_new_lazy(:timestamp, &DateTime.utc_now/0)
    |> Map.update(:content, [], fn
      content when is_binary(content) -> [Text.new(content)]
      content -> content
    end)
    |> Map.update(:origin, nil, fn
      %Model{dialects: %{text: dialect}} = model ->
        %{model: Model.to_ref(model), dialect: dialect}

      origin ->
        origin
    end)
    |> then(&struct!(__MODULE__, &1))
  end
end
