defmodule Omni.Request do
  # Request orchestration for LLM API calls.
  #
  # Handles validation, request building, streaming execution, and event parsing.
  # Separates orchestration logic from the Provider behaviour and Dialect behaviour,
  # composing them into a complete request pipeline.
  #
  # Public API:
  #   - build/3 — validates opts, builds a %Req.Request{} via dialect + provider
  #   - stream/3 — executes a built request, returns a %StreamingResponse{}
  #
  # Internal (public but undocumented):
  #   - validate/2 — three-tier config merge + Peri validation
  #   - parse_event/2 — dialect handle_event + provider modify_events
  #   - validate_context/2 — checks attachment media types against model modalities
  @moduledoc false

  alias Omni.Content.Attachment
  alias Omni.{Context, Model, Parsers, StreamingResponse}

  import Omni.Util, only: [maybe_put: 3]

  @schema %{
    # Config (type-loose — validated by infrastructure, not user input)
    api_key: :any,
    base_url: :any,
    auth_header: {:string, {:default, "authorization"}},
    headers: {:map, {:default, %{}}},
    plug: :any,
    models: :any,

    # Inference (type-strict)
    max_tokens: :integer,
    temperature: {:either, {:integer, :float}},
    timeout: {:integer, {:default, 300_000}},
    cache: {:enum, [:short, :long]},
    metadata: :map,
    thinking:
      {:either,
       {{:enum, [false, :low, :medium, :high, :xhigh, :max]},
        {:schema, %{effort: {:enum, [:low, :medium, :high, :xhigh, :max]}, budget: :integer}}}},
    output: :map
  }

  @doc """
  Builds an authenticated `%Req.Request{}` from a model, context, and options.

  Options can be a keyword list or map. Validates all options via `validate/2`,
  then delegates body/path building to the dialect, applies provider modifications,
  and returns the final request ready for execution.
  """
  @spec build(Model.t(), Context.t(), keyword() | map()) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def build(%Model{} = model, %Context{} = context, opts) do
    with {:ok, opts} <- validate(model, opts),
         :ok <- validate_context(model, context) do
      url =
        model
        |> model.dialect.handle_path(opts)
        |> model.provider.build_url(opts)

      body =
        model
        |> model.dialect.handle_body(context, opts)
        |> model.provider.modify_body(context, opts)

      req =
        [method: :post, url: url, json: body, receive_timeout: opts[:timeout], into: :self]
        |> maybe_put(:headers, opts[:headers])
        |> maybe_put(:plug, opts[:plug])
        |> Req.new()

      model.provider.authenticate(req, opts)
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

    with {:ok, resp} <- Req.request(req), :ok <- check_status(resp) do
      parser = select_parser(resp)

      deltas =
        resp.body
        |> parser.stream()
        |> Stream.flat_map(&parse_event(model, &1))

      cancel = fn -> Req.cancel_async_response(resp) end
      raw = if raw?, do: {req, resp}

      {:ok, StreamingResponse.new(deltas, model: model, cancel: cancel, raw: raw)}
    end
  end

  @doc false
  @spec validate(Model.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def validate(%Model{} = model, opts) do
    config = Application.get_env(:omni, model.provider, [])
    schema = Map.merge(@schema, model.dialect.option_schema())

    # Three-tier merge: provider config <- app config <- call-site opts
    data =
      model.provider.config()
      |> Map.merge(Map.new(config), &merge_config/3)
      |> Map.merge(Map.new(opts), &merge_config/3)

    with :ok <- check_unknown_keys(data, schema),
         {:ok, validated} <- Peri.validate(schema, data) do
      {:ok, validated}
    end
  end

  @doc false
  @spec parse_event(Model.t(), map()) :: [{atom(), map() | term()}]
  def parse_event(%Model{} = model, raw_event) do
    deltas = model.dialect.handle_event(raw_event)
    model.provider.modify_events(deltas, raw_event)
  end

  @doc false
  @spec validate_context(Model.t(), Context.t()) :: :ok | {:error, term()}
  def validate_context(%Model{} = model, %Context{} = context) do
    Enum.reduce_while(context.messages, :ok, fn msg, :ok ->
      Enum.reduce_while(msg.content, :ok, fn
        %Attachment{media_type: mt}, :ok ->
          case check_modality(mt, model.input_modalities) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        _block, :ok ->
          {:cont, :ok}
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_modality("text/" <> _, _modalities), do: :ok
  defp check_modality("application/json", _modalities), do: :ok

  defp check_modality("image/" <> _, modalities) do
    if :image in modalities, do: :ok, else: {:error, {:unsupported_modality, :image}}
  end

  defp check_modality("application/pdf", modalities) do
    if :pdf in modalities, do: :ok, else: {:error, {:unsupported_modality, :pdf}}
  end

  defp check_modality("audio/" <> _, modalities) do
    if :audio in modalities, do: :ok, else: {:error, {:unsupported_modality, :audio}}
  end

  defp check_modality("video/" <> _, modalities) do
    if :video in modalities, do: :ok, else: {:error, {:unsupported_modality, :video}}
  end

  defp check_modality(mt, _modalities), do: {:error, {:unsupported_media_type, mt}}

  # -- Private helpers --

  defp select_parser(%Req.Response{} = resp) do
    if resp
       |> Req.Response.get_header("content-type")
       |> Enum.any?(&String.contains?(&1, "ndjson")),
       do: Parsers.NDJSON,
       else: Parsers.SSE
  end

  defp check_unknown_keys(data, schema) do
    unknown = Map.keys(data) -- Map.keys(schema)

    case unknown do
      [] -> :ok
      keys -> {:error, {:unknown_options, keys}}
    end
  end

  # Headers merge additively (not last-writer-wins)
  defp merge_config(:headers, a, b), do: Map.merge(a, b)
  defp merge_config(_key, _a, b), do: b

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
