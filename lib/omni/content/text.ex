defmodule Omni.Content.Text do
  @moduledoc """
  A text content block.

  The most common content type, representing plain text output from a model
  or text input from a user.
  """

  @enforce_keys [:text]
  defstruct [:text, :signature]

  @typedoc "A text content block."
  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  @doc "Creates a new text content block from a string, keyword list, or map."
  @spec new(String.t() | Enumerable.t()) :: t()
  def new(text) when is_binary(text), do: new(text: text)
  def new(attrs), do: struct!(__MODULE__, attrs)
end
