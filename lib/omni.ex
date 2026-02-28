defmodule Omni do
  @moduledoc """
  Elixir library for interacting with LLM APIs across multiple providers.
  """

  alias Omni.{Context, Loop, Model, Response, StreamingResponse}

  @doc group: :generation
  @doc """
  Streams a text generation request, returning a `%StreamingResponse{}`.

  The model can be a `%Model{}` struct or a `{provider_id, model_id}` tuple.
  The context can be a string, list of messages, or `%Context{}` struct.

  When tools with handlers are present in the context, automatically executes
  tool uses and loops until the model stops calling tools. Between rounds,
  synthetic `:tool_result` events are emitted for observability.

  ## Options

    * `:api_key` — API key for the provider
    * `:plug` — a Req test plug for stubbing HTTP responses
    * `:raw` — when `true`, attaches raw `{%Req.Request{}, %Req.Response{}}` tuples to the response (one per round)
    * `:max_steps` — maximum number of request rounds (default `:infinity`). Pass `1` for manual tool handling.
    * `:output` — a JSON Schema map for structured output. When set, the schema is sent to the provider for constrained decoding, and the response text is validated and decoded into `response.output`. Retries automatically on validation failure (up to 3 times).

  All other options are passed through to `Request.build/3`.
  """
  @spec stream_text(Model.t() | {atom(), String.t()}, term(), keyword()) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream_text(model, context, opts \\ [])

  def stream_text({provider_id, model_id}, context, opts) do
    with {:ok, model} <- Model.get(provider_id, model_id) do
      stream_text(model, context, opts)
    end
  end

  def stream_text(%Model{} = model, context, opts) do
    context = Context.new(context)
    {raw, opts} = Keyword.pop(opts, :raw, false)
    {max_steps, opts} = Keyword.pop(opts, :max_steps, :infinity)

    Loop.stream(model, context, opts, raw, max_steps)
  end

  @doc group: :generation
  @doc """
  Generates text by consuming a streaming response to completion.

  Accepts the same arguments as `stream_text/3`. Returns the final
  `%Response{}` after the stream is fully consumed.
  """
  @spec generate_text(Model.t() | {atom(), String.t()}, term(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def generate_text(model, context, opts \\ []) do
    with {:ok, stream} <- stream_text(model, context, opts) do
      StreamingResponse.complete(stream)
    end
  end

  # -- Delegates --

  @doc group: :models
  @doc "Looks up a model by provider ID and model ID from `:persistent_term`."
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc group: :models
  @doc "Returns all models for a provider, or an error if the provider is unknown."
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc group: :constructors
  @doc "Creates a new `%Omni.Tool{}` from a keyword list or map."
  defdelegate tool(attrs), to: Omni.Tool, as: :new

  @doc group: :constructors
  @doc "Creates a new `%Omni.Context{}` from a string, list of messages, keyword list, or map."
  defdelegate context(input), to: Omni.Context, as: :new

  @doc group: :constructors
  @doc "Creates a new `%Omni.Message{}` from a string, keyword list, or map."
  defdelegate message(input), to: Omni.Message, as: :new
end
