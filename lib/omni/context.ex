defmodule Omni.Context do
  @moduledoc """
  The context for a conversation with an LLM.

  A context is what a text request sends: the second argument to
  `Omni.generate_text/3` and `Omni.stream_text/3`. Both also take a string
  or a list of messages and build the context for you.
  [Contexts and messages](text-generation.md#contexts-and-messages) shows a
  conversation carried over several turns.

  ```elixir
  context = Omni.context(system: "You are a helpful assistant.", messages: [Omni.message("Hello!")])

  {:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", context)
  context = Omni.Context.push(context, response)
  ```

  ## Struct fields

  - `:system` - the system prompt, or `nil`
  - `:messages` - the conversation so far, as a list of `Omni.Message`
    structs, oldest first
  - `:tools` - the `Omni.Tool` structs the model may use
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

  A string is a single user message. A list of messages is the message
  history. A keyword list or map sets `:system`, `:messages` and `:tools`.
  An existing context is returned as is.
  """
  @spec new(Enumerable.t() | String.t() | [Message.t()] | t()) :: t()
  def new(attrs \\ [])
  def new(%__MODULE__{} = context), do: context
  def new(text) when is_binary(text), do: new(messages: [Message.new(text)])
  def new([%Message{} | _] = messages), do: new(messages: messages)
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Appends messages to the context.

  Takes one message, a list of messages, or an `Omni.Response`. A response
  adds all of its `:messages`, which after a tool loop includes every tool
  use and tool result along the way.
  """
  @spec push(t(), Message.t() | [Message.t()] | Response.t()) :: t()
  def push(%__MODULE__{} = context, %Message{} = message) do
    push(context, [message])
  end

  def push(%__MODULE__{} = context, %Response{} = response) do
    push(context, response.messages)
  end

  def push(%__MODULE__{} = context, messages) when is_list(messages) do
    %{context | messages: context.messages ++ messages}
  end
end
