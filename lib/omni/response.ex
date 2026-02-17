defmodule Omni.Response do
  @moduledoc """
  The result of a text generation request.

  Wraps an assistant `%Message{}` with generation metadata. The response is an
  envelope — the message itself can be extracted and appended directly to a
  conversation context.
  """

  alias Omni.{Message, Model, Usage}

  @enforce_keys [:message, :model, :usage, :stop_reason]
  defstruct [:message, :model, :usage, :stop_reason, :error, :raw]

  @typedoc "A generation response envelope."
  @type t :: %__MODULE__{
          message: Message.t(),
          model: Model.t(),
          usage: Usage.t(),
          stop_reason: :stop | :length | :tool_use | :error,
          error: String.t() | nil,
          raw: {Req.Request.t(), Req.Response.t()} | nil
        }

  @doc "Creates a new response struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
