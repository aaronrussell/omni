defmodule Omni.Response do
  @moduledoc """
  The result of a text generation request.

  Returned by `Omni.generate_text/3` and `Omni.StreamingResponse.complete/1`.
  It holds the assistant's message, why the model stopped and what the
  request cost. To continue the conversation, add the response to the
  context with `Omni.Context.push/2`.

  ```elixir
  {:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", "Hello!")

  response.message.content  #=> [%Omni.Content.Text{text: "Hello! How can I help?"}]
  response.stop_reason      #=> :stop
  response.usage.total_cost #=> 0.000213
  ```

  ## Struct fields

  - `:model` - the `Omni.Model` that handled the request
  - `:message` - the assistant's final message
  - `:messages` - every message this request produced. Usually just
    `[response.message]`; after a tool loop, each assistant message and
    each user message of tool results, in order
  - `:output` - the validated, decoded output when the `:output` option was
    set, else `nil`
  - `:stop_reason` - why generation ended (see `t:stop_reason/0`)
  - `:error` - a description of the error when `:stop_reason` is `:error`,
    else `nil`
  - `:raw` - a list of `{%Req.Request{}, %Req.Response{}}` tuples, one per
    request, when the `:raw` option was set
  - `:usage` - the `Omni.Usage` for the whole request, summed over every
    step of a tool loop
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
    usage: %Usage{}
  ]

  @typedoc "A generation response envelope."
  @type t :: %__MODULE__{
          model: Model.t(),
          message: Message.t() | nil,
          messages: [Message.t()],
          output: map() | list() | nil,
          stop_reason: stop_reason(),
          error: String.t() | nil,
          raw: [{Req.Request.t(), Req.Response.t()}] | nil,
          usage: Usage.t()
        }

  @typedoc """
  Why generation ended.

  - `:stop` - the model finished
  - `:length` - the token limit was reached
  - `:tool_use` - the model used a tool that Omni did not run
  - `:refusal` - the model or provider declined, on content or safety grounds
  - `:error` - the stream failed part-way (see the `:error` field)
  - `:cancelled` - generation was cancelled. Omni never sets this itself;
    it is for code built on Omni that cancels a stream and keeps the
    partial response
  """
  @type stop_reason :: :stop | :length | :tool_use | :refusal | :error | :cancelled

  @doc "Creates a new response struct from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
