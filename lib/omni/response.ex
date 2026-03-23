defmodule Omni.Response do
  @moduledoc """
  The result of a text generation request.

  Returned by `Omni.generate_text/3` and `Omni.StreamingResponse.complete/1`.
  Wraps the assistant's message with generation metadata — extract
  `response.message` to continue a multi-turn conversation.

  ## Struct fields

    * `:model` — the `%Model{}` that handled the request
    * `:message` — the assistant's response message (the last assistant message)
    * `:messages` — all messages from this generation. For single-step calls,
      `[response.message]`. For multi-step tool loops, includes assistant and
      tool-result messages from every step
    * `:output` — validated, decoded map when the `:output` option was set
    * `:stop_reason` — why generation ended: `:stop` (natural completion),
      `:length` (token limit reached), `:tool_use` (model invoked a tool),
      `:refusal` (declined due to content or safety policy), or `:error`
    * `:error` — error description when `stop_reason` is `:error`, otherwise `nil`
    * `:raw` — list of `{%Req.Request{}, %Req.Response{}}` tuples when `:raw`
      was set (one per generation step)
    * `:usage` — cumulative `%Usage{}` token counts and costs for this generation

  """

  alias Omni.{Message, Model, Usage}

  @enforce_keys [:model, :stop_reason]
  defstruct [
    :model,
    :message,
    :output,
    :stop_reason,
    :error,
    :raw,
    messages: [],
    node_ids: nil,
    usage: %Usage{}
  ]

  @typedoc "A generation response envelope."
  @type t :: %__MODULE__{
          model: Model.t(),
          message: Message.t() | nil,
          messages: [Message.t()],
          node_ids: [non_neg_integer()] | nil,
          output: map() | list() | nil,
          stop_reason: stop_reason(),
          error: String.t() | nil,
          raw: [{Req.Request.t(), Req.Response.t()}] | nil,
          usage: Usage.t()
        }

  @typedoc "Why generation ended."
  @type stop_reason :: :stop | :length | :tool_use | :refusal | :error | :cancelled

  @doc "Creates a new response struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
