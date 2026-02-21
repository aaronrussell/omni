defmodule Omni do
  @moduledoc """
  Elixir library for interacting with LLM APIs across multiple providers.
  """

  alias Omni.{Context, Model, Provider, Response, SSE, StreamingResponse}

  @doc """
  Streams a text generation request, returning a `%StreamingResponse{}`.

  The model can be a `%Model{}` struct or a `{provider_id, model_id}` tuple.
  The context can be a string, list of messages, or `%Context{}` struct.

  ## Options

    * `:api_key` — API key for the provider
    * `:plug` — a Req test plug for stubbing HTTP responses
    * `:raw` — when `true`, attaches the raw `{%Req.Request{}, %Req.Response{}}` to the response

  All other options are passed through to `Provider.build_request/3`.
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
    {plug, opts} = Keyword.pop(opts, :plug)
    {raw?, opts} = Keyword.pop(opts, :raw, false)

    with {:ok, req} <- Provider.build_request(model, context, opts),
         {:ok, resp} <- req |> maybe_merge_plug(plug) |> Req.request(),
         :ok <- check_status(resp) do
      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&Provider.parse_event(model.provider, &1))

      cancel = fn -> Req.cancel_async_response(resp) end
      raw = if raw?, do: {req, resp}

      {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
    end
  end

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

  # -- Private helpers --

  defp maybe_merge_plug(req, nil), do: req
  defp maybe_merge_plug(req, plug), do: Req.merge(req, plug: plug)

  defp check_status(%Req.Response{status: 200}), do: :ok

  defp check_status(%Req.Response{status: status, body: body}) do
    {:error, {:http_error, status, read_error_body(body)}}
  end

  defp read_error_body(%Req.Response.Async{} = async) do
    async |> Enum.to_list() |> IO.iodata_to_binary() |> try_decode_json()
  end

  defp read_error_body(body) when is_binary(body), do: try_decode_json(body)
  defp read_error_body(body), do: body

  defp try_decode_json(binary) do
    case JSON.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> binary
    end
  end

  # -- Delegates --

  @doc "Looks up a model by provider ID and model ID from `:persistent_term`."
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc "Returns all models for a provider, or an error if the provider is unknown."
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc "Creates a new `%Omni.Tool{}` from a keyword list or map."
  defdelegate tool(attrs), to: Omni.Tool, as: :new

  @doc "Creates a new `%Omni.Context{}` from a string, list of messages, keyword list, or map."
  defdelegate context(input), to: Omni.Context, as: :new

  @doc "Creates a new `%Omni.Message{}` from a string, keyword list, or map."
  defdelegate message(input), to: Omni.Message, as: :new
end
