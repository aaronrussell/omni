defmodule Omni.Response do
  @moduledoc """
  The result of a text generation request.

  Wraps an assistant `%Message{}` with generation metadata. The response is an
  envelope — the message itself can be extracted and appended directly to a
  conversation context.

  The `messages` field contains all messages from the generation — for a
  single-step call this is `[response.message]`, for a multi-step tool loop
  it includes assistant and tool-result user messages from every step.
  """

  alias Omni.{Message, Model, Usage}

  @enforce_keys [:message, :model, :usage, :stop_reason]
  defstruct [:message, :model, :usage, :stop_reason, :error, :raw, messages: []]

  @typedoc "A generation response envelope."
  @type t :: %__MODULE__{
          message: Message.t(),
          model: Model.t(),
          usage: Usage.t(),
          stop_reason: :stop | :length | :tool_use | :error,
          error: String.t() | nil,
          raw: [{Req.Request.t(), Req.Response.t()}] | nil,
          messages: [Message.t()]
        }

  @doc "Creates a new response struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
