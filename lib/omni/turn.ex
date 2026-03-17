defmodule Omni.Turn do
  @moduledoc """
  A single conversation turn: a list of messages and their token usage.

  Appears in `%MessageTree{}` as the data for each node, and on `%Response{}`
  to carry accumulated messages and usage from a generation request. The `id`
  and `parent` fields position the turn within a conversation tree — branching,
  regeneration, and navigation all work through these pointers.

  For stateless `generate_text`/`stream_text` calls, the turn defaults to
  `id: 0, parent: nil`. Pass `:turn_id` and `:turn_parent` options to place
  the turn in a manually managed tree.
  """

  alias Omni.{Message, Usage}

  defstruct id: 0, parent: nil, messages: [], usage: %Usage{}

  @typedoc "A conversation turn."
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          parent: non_neg_integer() | nil,
          messages: [Message.t()],
          usage: Usage.t()
        }

  @typedoc "Integer turn identifier, assigned sequentially by `MessageTree.push/3`."
  @type id :: non_neg_integer()

  @doc "Creates a new turn from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
