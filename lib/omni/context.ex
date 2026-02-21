defmodule Omni.Context do
  @moduledoc """
  The context for a conversation with an LLM.

  Wraps a system prompt, a list of messages, and a list of tools. Convenience
  constructors allow creating a context from a plain string (single user
  message) or a list of messages directly.
  """

  alias Omni.{Message, Tool}

  defstruct [:system, messages: [], tools: []]

  @typedoc "A conversation context."
  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()]
        }

  @doc """
  Creates a new context from a string, list of messages, keyword list, or map.

  A string is treated as a single user message. A list is treated as messages.
  """
  @spec new(String.t() | [Message.t()] | t() | Enumerable.t()) :: t()
  def new(%__MODULE__{} = context), do: context
  def new(text) when is_binary(text), do: new(messages: [Message.new(text)])
  def new([%Message{} | _] = messages), do: new(messages: messages)
  def new(attrs), do: struct!(__MODULE__, attrs)
end
