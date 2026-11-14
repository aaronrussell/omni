defmodule Omni.Content.ToolUse do
  @moduledoc """
  A tool use content block: the model asking for a tool to be run.

  Only a model produces these, in assistant messages. Each is answered by an
  `Omni.Content.ToolResult` in the next user message.

  ## Struct fields

  - `:id` - the provider's id for this tool use, which its result names
  - `:name` - the name of the tool
  - `:input` - the arguments, as the map the model wrote, with string keys
  - `:signature` - a token some providers attach and expect back on later
    turns. Omni handles it
  """

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input, :signature]

  @typedoc "The model's request to run a named tool with the given input."
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map(),
          signature: String.t() | nil
        }

  @doc "Creates a new tool use content block from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
