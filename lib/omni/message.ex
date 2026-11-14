defmodule Omni.Message do
  @moduledoc """
  A message in a conversation.

  A message has a role and a list of content blocks. There are two roles,
  `:user` and `:assistant`. There is no `:tool` role: a tool result is an
  `Omni.Content.ToolResult` block inside a user message.
  [Contexts and messages](text-generation.md#contexts-and-messages) shows
  messages in a conversation.

  ```elixir
  Omni.message("What is Elixir?")
  Omni.message(role: :assistant, content: "A functional language on the BEAM.")
  ```

  ## Struct fields

  - `:role` - `:user` or `:assistant`
  - `:content` - the content blocks, in order (see `t:content/0`)
  - `:timestamp` - when the message was created, in UTC. Set by `new/1`
    unless given
  - `:origin` - on assistant messages Omni produced, the model that wrote
    the message and the dialect it spoke; otherwise `nil` (see
    [Origin](#module-origin))
  - `:private` - data a provider needs back on later turns, which Omni
    writes and reads. Leave it as it is, and keep it when storing messages

  ## Origin

  Thinking blocks and signatures only mean something to the provider that
  wrote them. Omni stamps each assistant message it produces with its
  origin, and on later requests sends thinking, signatures and `:private`
  back only to the same provider and dialect. A message from anywhere else,
  or with no origin, is sent without them; its text and tool uses are kept.
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

  A string is a user message with that text as content. String content is
  wrapped in an `Omni.Content.Text` block, and so is each string in a
  content list:

  ```elixir
  Message.new(role: :user, content: ["What's in this image?", Attachment.new({:base64, png}, "image/png")])
  ```

  `:timestamp` defaults to `DateTime.utc_now/0`.

  `:origin` takes the `Omni.Model` that wrote the message, recorded as its
  reference and dialect, or an origin map as is:

  ```elixir
  Message.new(role: :assistant, content: "Hi", origin: model)
  ```
  """
  @spec new(Enumerable.t() | String.t() | t()) :: t()
  def new(%__MODULE__{} = message), do: message

  def new(text) when is_binary(text), do: new(role: :user, content: text)

  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.put_new_lazy(:timestamp, &DateTime.utc_now/0)
    |> Map.update(:content, [], &content/1)
    |> Map.update(:origin, nil, fn
      %Model{dialects: %{text: dialect}} = model ->
        %{model: Model.to_ref(model), dialect: dialect}

      origin ->
        origin
    end)
    |> then(&struct!(__MODULE__, &1))
  end

  defp content(text) when is_binary(text), do: [Text.new(text)]
  defp content(blocks) when is_list(blocks), do: Enum.map(blocks, &block/1)
  defp content(other), do: other

  defp block(text) when is_binary(text), do: Text.new(text)
  defp block(block), do: block
end
