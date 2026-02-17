defmodule Omni.Content.Thinking do
  @moduledoc """
  A thinking content block representing the model's chain-of-thought reasoning.

  When `text` is `nil`, the thinking content was redacted by the provider. The
  `signature` field is an opaque token used to verify thinking block integrity
  across round trips.
  """

  @enforce_keys [:text]
  defstruct [:text, :signature]

  @typedoc "A thinking content block. `text` is `nil` when redacted."
  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  @doc "Creates a new thinking content block from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
