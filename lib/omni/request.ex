defmodule Omni.Request do
  @moduledoc """
  Request orchestration for LLM API calls.

  Handles validation, request building, streaming execution, and event parsing.
  Separates orchestration logic from the Provider behaviour and Dialect behaviour,
  composing them into a complete request pipeline.
  """

  alias Omni.{Context, Model, SSE, StreamingResponse}

  @config_keys ~w(api_key base_url auth_header headers plug timeout)a

  @doc """
  Builds an authenticated `%Req.Request{}` from a model, context, and options.

  Accepts either raw keyword opts (validated internally) or a pre-validated map
  from `validate/2`. Delegates body/path building to the dialect, applies provider
  modifications, and returns the final request ready for execution.
  """
  @spec build(Model.t(), Context.t(), keyword() | map()) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def build(%Model{} = model, %Context{} = context, opts) when is_list(opts) do
    with {:ok, validated} <- validate(model, opts) do
      build(model, context, validated)
    end
  end

  def build(%Model{} = model, %Context{} = context, %{} = opts) do
    dialect = model.dialect
    provider = model.provider

    body = dialect.handle_body(model, context, opts)
    path = dialect.handle_path(model, opts)
    body = provider.modify_body(body, opts)

    url = provider.build_url(path, opts)

    req =
      Req.new(method: :post, url: url, json: body, into: :self)
      |> merge_headers(provider.config()[:headers], opts[:headers])

    with {:ok, req} <- provider.authenticate(req, opts) do
      {:ok, maybe_merge_plug(req, opts[:plug])}
    end
  end

  @doc """
  Executes a built request and returns a `%StreamingResponse{}`.

  Runs the request, checks the HTTP status, sets up the SSE parsing pipeline
  with `parse_event/2`, and wraps everything in a `StreamingResponse`.
  """
  @spec stream(Req.Request.t(), Model.t(), keyword() | map()) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream(%Req.Request{} = req, %Model{} = model, opts) do
    raw? = opts[:raw] || false

    with {:ok, resp} <- Req.request(req),
         :ok <- check_status(resp) do
      deltas =
        resp.body
        |> SSE.stream()
        |> Stream.flat_map(&parse_event(model, &1))

      cancel = fn -> Req.cancel_async_response(resp) end
      raw = if raw?, do: {req, resp}

      {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
    end
  end

  @doc false
  @spec validate(Model.t(), keyword()) :: {:ok, map()}
  def validate(%Model{} = model, opts) when is_list(opts) do
    provider = model.provider
    config = provider.config()
    app_config = Application.get_env(:omni, provider, [])

    {config_opts, inference_opts} = Keyword.split(opts, @config_keys)

    unified =
      inference_opts
      |> Map.new()
      |> Map.put_new_lazy(:api_key, fn ->
        cond do
          Keyword.has_key?(config_opts, :api_key) -> config_opts[:api_key]
          Keyword.has_key?(app_config, :api_key) -> app_config[:api_key]
          true -> config[:api_key]
        end
      end)
      |> Map.put_new_lazy(:base_url, fn ->
        Keyword.get(config_opts, :base_url) || config[:base_url]
      end)
      |> Map.put_new_lazy(:auth_header, fn ->
        Keyword.get(config_opts, :auth_header) || config[:auth_header] || "authorization"
      end)
      |> Map.put_new_lazy(:headers, fn ->
        Keyword.get(config_opts, :headers)
      end)
      |> Map.put_new_lazy(:plug, fn ->
        Keyword.get(config_opts, :plug)
      end)
      |> Map.put_new_lazy(:timeout, fn ->
        Keyword.get(config_opts, :timeout, 300_000)
      end)

    {:ok, unified}
  end

  @doc false
  @spec parse_event(Model.t(), map()) :: [{atom(), map()}]
  def parse_event(%Model{} = model, raw_event) do
    deltas = model.dialect.handle_event(raw_event)
    model.provider.modify_events(deltas, raw_event)
  end

  # -- Private helpers --

  defp maybe_merge_plug(req, nil), do: req
  defp maybe_merge_plug(req, plug), do: Req.merge(req, plug: plug)

  defp merge_headers(req, config_headers, call_headers) do
    req
    |> apply_headers(config_headers)
    |> apply_headers(call_headers)
  end

  defp apply_headers(req, nil), do: req

  defp apply_headers(req, headers) when is_map(headers) do
    Enum.reduce(headers, req, fn {k, v}, acc -> Req.Request.put_header(acc, k, v) end)
  end

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
end
