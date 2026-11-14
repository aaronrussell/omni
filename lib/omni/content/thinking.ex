defmodule Omni.Content.Thinking do
  @moduledoc """
  A thinking content block: the model's reasoning before it answers.

  Only a model produces these. Keep them in the conversation: Omni sends
  them back to the provider that wrote them, which models need to continue
  their reasoning across tool use (see [Thinking](text-generation.md#thinking)).

  ## Struct fields

  - `:text` - the reasoning, or a summary of it. `nil` when the provider
    returns it encrypted
  - `:redacted_data` - encrypted reasoning, which can be sent back but not
    read. `:text` is `nil` when this is set
  - `:signature` - a token the provider uses to check the block when it is
    sent back
  - `:id` - the block's id, for APIs that refer to reasoning by id (OpenAI
    Responses)
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
