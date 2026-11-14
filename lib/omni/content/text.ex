defmodule Omni.Content.Text do
  @moduledoc """
  A text content block.

  The most common block: text written by a user or by the model. A plain
  string becomes one wherever message content is built, so you rarely call
  `new/1` yourself.

  ## Struct fields

  - `:text` - the text
  - `:signature` - a token some providers attach to their output and expect
    back on later turns. Omni handles it
  """

  @enforce_keys [:text]
  defstruct [:text, :signature]

  @typedoc "Text content with an optional integrity signature."
  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  @doc "Creates a new text content block from a string, keyword list, or map."
  @spec new(String.t() | Enumerable.t()) :: t()
  def new(text) when is_binary(text), do: new(text: text)
  def new(attrs), do: struct!(__MODULE__, attrs)
end
