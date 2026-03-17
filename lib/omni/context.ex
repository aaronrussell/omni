defmodule Omni.Context do
  @moduledoc """
  The context for a conversation with an LLM.

  Wraps a system prompt, a list of messages, and a list of tools — passed as
  the second argument to `Omni.generate_text/3` and `Omni.stream_text/3`.
  """

  alias Omni.{Message, Response, Tool}

  defstruct [:system, messages: [], tools: []]

  @typedoc "System prompt, messages, and tools for a generation request."
  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()]
        }

  @doc """
  Creates a new context from a string, list of messages, keyword list, or map.

  A string is treated as a single user message. A list is treated as messages.
  """
  @spec new(Enumerable.t() | String.t() | [Message.t()] | t()) :: t()
  def new(attrs \\ [])
  def new(%__MODULE__{} = context), do: context
  def new(text) when is_binary(text), do: new(messages: [Message.new(text)])
  def new([%Message{} | _] = messages), do: new(messages: messages)
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Appends messages to the context.

  Accepts a single `%Message{}`, a list of messages, or a `%Response{}`
  (extracts its `messages` field — the right choice after a tool loop).
  """
  @spec push(t(), Message.t() | [Message.t()] | Response.t()) :: t()
  def push(%__MODULE__{} = context, %Message{} = message) do
    push(context, [message])
  end

  def push(%__MODULE__{} = context, %Response{} = response) do
    push(context, response.turn.messages)
  end

  def push(%__MODULE__{} = context, messages) when is_list(messages) do
    %{context | messages: context.messages ++ messages}
  end
end
