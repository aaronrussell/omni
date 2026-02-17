defmodule Omni.Content.ToolUse do
  @moduledoc """
  A tool use content block representing the model's intent to invoke a tool.

  Appears in assistant messages when the model decides to use a tool. The `id`
  is a provider-assigned identifier that links this block to its corresponding
  `Omni.Content.ToolResult`.
  """

  defstruct [:id, :name, :input, :signature]

  @typedoc "A tool use content block."
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
