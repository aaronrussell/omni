defmodule Omni.Content.Thinking do
  @moduledoc """
  A thinking content block representing the model's chain-of-thought reasoning.

  When `text` is `nil` and `redacted_data` is present, the block contains
  encrypted/redacted thinking content that must round-trip but cannot be
  displayed. The `signature` field is an opaque token used to verify thinking
  block integrity across round trips. `id` names the block for APIs that refer
  to reasoning by id on replay (OpenAI Responses reasoning items).
  """

  defstruct [:text, :signature, :redacted_data, :id]

  @typedoc "Chain-of-thought reasoning. `text` is `nil` when the content is redacted."
  @type t :: %__MODULE__{
          text: String.t() | nil,
          signature: String.t() | nil,
          redacted_data: String.t() | nil,
          id: String.t() | nil
        }

  @doc "Creates a new thinking content block from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
