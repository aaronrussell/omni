defmodule Omni.Response do
  @moduledoc """
  The result of a text generation request.

  Returned by `Omni.generate_text/3` and `Omni.StreamingResponse.complete/1`.
  Wraps the assistant's message with generation metadata — extract
  `response.message` to continue a multi-turn conversation.

  ## Struct fields

    * `:model` — the `%Model{}` that handled the request
    * `:message` — the assistant's response message
    * `:messages` — all messages from the generation. Single-step calls produce
      `[response.message]`; multi-step tool loops include assistant and
      tool-result messages from every round
    * `:output` — validated, decoded map when the `:output` option was set
    * `:stop_reason` — why generation ended: `:stop` (natural completion),
      `:length` (token limit reached), `:tool_use` (model invoked a tool),
      `:refusal` (declined due to content or safety policy), or `:error`
    * `:usage` — token counts and costs (see `Omni.Usage`)
    * `:error` — error description when `stop_reason` is `:error`, otherwise `nil`
    * `:raw` — list of `{%Req.Request{}, %Req.Response{}}` tuples when `:raw`
      was set (one per generation round)

  """

  alias Omni.{Message, Model, Usage}

  @enforce_keys [:message, :model, :usage, :stop_reason]
  defstruct [:message, :model, :usage, :stop_reason, :error, :raw, :output, messages: []]

  @typedoc "A generation response envelope."
  @type t :: %__MODULE__{
          message: Message.t(),
          model: Model.t(),
          usage: Usage.t(),
          stop_reason: stop_reason(),
          error: String.t() | nil,
          raw: [{Req.Request.t(), Req.Response.t()}] | nil,
          output: map() | list() | nil,
          messages: [Message.t()]
        }

  @typedoc "Why generation ended."
  @type stop_reason :: :stop | :length | :tool_use | :refusal | :error

  @doc "Creates a new response struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
