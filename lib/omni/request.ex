defmodule Omni.Request do
  # Request orchestration for LLM API calls.
  #
  # Handles validation, request building, execution, and event parsing.
  # Composes the model's dialect (wire format) and provider (endpoint, auth,
  # optional module hooks) into a complete request pipeline. Everything comes
  # from the %Model{} — its embedded %Provider{} and its dialects — so nothing
  # is looked up at request time. The struct being sent picks the capability:
  # a %Context{} is text generation, a %Decision{} a decision.
  #
  # Public API:
  #   - build/3 — validates opts, builds a %Req.Request{} via dialect + provider
  #   - stream/3 — executes a built text request, returns a %StreamingResponse{}
  #   - send/4 — executes a built decision request, returns the answered %Decision{}
  #
  # Internal (public but undocumented):
  #   - validate/3 — provider + call-site merge + Peri validation
  #   - parse_event/2 — dialect handle_event
  #   - validate_context/2 — checks attachment media types against model modalities
  @moduledoc false

  alias Omni.Content.{Attachment, Text, Thinking, ToolUse}
  alias Omni.{Context, Decision, Message, Model, Parsers, Provider, StreamingResponse, Usage}
  alias Omni.Provider.Endpoint

  import Omni.Util, only: [maybe_put: 3]

  # Config options every capability takes (type-loose — validated by
  # infrastructure, not user input).
  @config_schema %{
    api_key: :any,
    host: :string,
    headers: {:map, {:default, %{}}},
    plug: :any,
    timeout: {:integer, {:default, 300_000}}
  }

  # Text generation options (type-strict).
  @text_schema %{
    max_tokens: :integer,
    temperature: {:either, {:integer, :float}},
    cache: {:enum, [:short, :long]},
    metadata: :map,
    thinking:
      {:either,
       {{:enum, [false, true, :low, :medium, :high, :xhigh, :max]},
        {:schema, %{effort: {:enum, [:low, :medium, :high, :xhigh, :max]}, budget: :integer}}}},
    output: {:either, {:map, {:tuple, [:atom, :any]}}}
  }

  @doc """
  Builds an authenticated `%Req.Request{}` from a model, a context or
  decision, and options.

  Options can be a keyword list or map. Validates all options via
  `validate/3`, then delegates body/path building to the model's dialect for
  the capability, applies the provider's auth and module hooks, and returns
  the final request ready for execution.
  """
  @spec build(Model.t(), Context.t() | Decision.t(), keyword() | map()) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def build(%Model{provider: %Provider{} = provider} = model, %Context{} = context, opts) do
    with {:ok, dialect} <- Model.dialect(model, :text),
         {:ok, endpoint} <- Provider.endpoint(provider, dialect),
         {:ok, opts} <- validate(model, :text, opts),
         :ok <- validate_context(model, context),
         {:ok, url} <- url(endpoint, dialect, model, opts) do
      context = drop_foreign_replay(context, provider, dialect)

      body =
        model
        |> dialect.handle_body(context, opts)
        |> modify_body(provider, model, context, opts)

      [method: :post, url: url, json: body, receive_timeout: opts[:timeout], into: :self]
      |> new_request(provider, dialect, opts)
    end
  end

  def build(%Model{provider: %Provider{} = provider} = model, %Decision{} = decision, opts) do
    with {:ok, dialect} <- Model.dialect(model, :decision),
         {:ok, endpoint} <- Provider.endpoint(provider, dialect),
         {:ok, opts} <- validate(model, :decision, opts),
         :ok <- Decision.validate(decision),
         {:ok, url} <- url(endpoint, dialect, model, opts) do
      body =
        model
        |> dialect.handle_body(decision, opts)
        |> modify_body(provider, model, decision, opts)

      [method: :post, url: url, json: body, receive_timeout: opts[:timeout]]
      |> new_request(provider, dialect, opts)
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

  @doc """
  Executes a built decision request and returns the answered decision.

  Runs the request, checks the HTTP status, hands the decoded JSON body to
  the dialect's `handle_response/3`, and prices the usage from the model.
  With `raw: true` the `{req, resp}` pair is attached as `:raw`.
  """
  @spec send(Req.Request.t(), Model.t(), Decision.t(), keyword() | map()) ::
          {:ok, Decision.t()} | {:error, term()}
  def send(%Req.Request{} = req, %Model{} = model, %Decision{} = decision, opts) do
    with {:ok, dialect} <- Model.dialect(model, :decision),
         {:ok, resp} <- Req.request(req),
         :ok <- check_status(resp),
         {:ok, body} <- decode_body(resp.body),
         {:ok, %Decision{} = decision} <- dialect.handle_response(body, decision, model) do
      usage = Usage.price(decision.usage || %Usage{}, model)
      raw = if opts[:raw], do: {req, resp}

      {:ok, %{decision | usage: usage, model: model, raw: raw}}
    end
  end

  @doc false
  @spec validate(Model.t(), Model.capability(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def validate(%Model{provider: %Provider{} = provider} = model, capability, opts) do
    # Two tiers: the provider (which already absorbed app config) <- call site
    data =
      provider
      |> Map.take([:api_key, :headers])
      |> Map.merge(Map.new(opts), &merge_config/3)

    with {:ok, dialect} <- Model.dialect(model, capability),
         schema = option_schema(capability, dialect),
         :ok <- check_unknown_keys(data, schema) do
      Peri.validate(schema, data)
    end
  end

  defp option_schema(:text, dialect),
    do: @config_schema |> Map.merge(@text_schema) |> Map.merge(dialect.option_schema())

  defp option_schema(:decision, dialect),
    do: Map.merge(@config_schema, dialect.option_schema())

  @doc false
  @spec parse_event(Model.t(), map()) :: [{atom(), map() | term()}]
  def parse_event(%Model{} = model, raw_event) do
    dialect!(model).handle_event(raw_event, model)
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

  defp dialect!(%Model{} = model) do
    case Model.dialect(model, :text) do
      {:ok, dialect} -> dialect
      {:error, _} -> raise ArgumentError, "model #{inspect(model.id)} has no text dialect"
    end
  end

  defp new_request(req_opts, provider, dialect, opts) do
    req =
      req_opts
      |> maybe_put(:headers, opts[:headers])
      |> maybe_put(:plug, opts[:plug])
      |> Req.new()

    with {:ok, req} <- authenticate(req, auth_scheme(provider, dialect), opts[:api_key]) do
      modify_request(req, provider, opts)
    end
  end

  # The endpoint's whole URL, its origin swapped by a call-site host:, plus
  # the dialect's resource path. Some catalog URLs end in a slash; dialect
  # paths start with one.
  defp url(%Endpoint{base_url: base_url}, dialect, model, opts) do
    with {:ok, base_url} <- put_host(base_url, opts[:host]) do
      if is_binary(base_url) and not Endpoint.placeholder?(base_url),
        do: {:ok, String.trim_trailing(base_url, "/") <> dialect.handle_path(model, opts)},
        else: {:error, {:no_base_url, dialect}}
    end
  end

  defp put_host(base_url, nil), do: {:ok, base_url}

  defp put_host(base_url, host) do
    with :ok <- Endpoint.validate_host(host), do: {:ok, Endpoint.put_host(base_url, host)}
  end

  # Thinking, signatures and `private` go back only to the provider and
  # dialect that produced them: another API's signatures fail validation, and
  # another model's readable thinking would pass as this model's own. Within
  # one provider and dialect everything is sent, and the API drops what the
  # model can't read. A message with no origin counts as foreign. One left
  # empty (it held only thinking) is dropped, since APIs reject empty turns.
  defp drop_foreign_replay(%Context{} = context, %Provider{id: provider_id}, dialect) do
    messages =
      Enum.flat_map(context.messages, fn
        %Message{role: :assistant, origin: %{model: {^provider_id, _}, dialect: ^dialect}} = msg ->
          [msg]

        %Message{role: :assistant} = msg ->
          case strip_replay(msg) do
            %Message{content: []} -> []
            msg -> [msg]
          end

        msg ->
          [msg]
      end)

    %{context | messages: messages}
  end

  defp strip_replay(%Message{} = message) do
    content =
      message.content
      |> Enum.reject(&match?(%Thinking{}, &1))
      |> Enum.map(fn
        %Text{} = text -> %{text | signature: nil}
        %ToolUse{} = use -> %{use | signature: nil}
        block -> block
      end)

    %{message | content: content, private: %{}}
  end

  defp modify_body(body, provider, model, input, opts) do
    if Provider.callback?(provider, :modify_body, 4),
      do: provider.module.modify_body(body, model, input, opts),
      else: body
  end

  defp modify_request(req, provider, opts) do
    if Provider.callback?(provider, :modify_request, 3),
      do: provider.module.modify_request(req, provider, opts),
      else: {:ok, req}
  end

  # :dialect (and unset, for hand-built structs) uses the scheme of the
  # dialect's home API, so gateways authenticate each model correctly.
  defp auth_scheme(%Provider{auth: auth}, dialect) when auth in [nil, :dialect],
    do: dialect.auth()

  defp auth_scheme(%Provider{auth: auth}, _dialect), do: auth

  defp authenticate(req, :none, _api_key), do: {:ok, req}

  defp authenticate(req, :bearer, api_key) do
    with {:ok, key} <- Provider.resolve_auth(api_key) do
      {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
    end
  end

  defp authenticate(req, {:header, name}, api_key) do
    with {:ok, key} <- Provider.resolve_auth(api_key) do
      {:ok, Req.Request.put_header(req, name, key)}
    end
  end

  # Ollama streams NDJSON: local Ollama labels it `application/x-ndjson`,
  # ollama.com plain `application/json`. SSE is everything else.
  defp select_parser(%Req.Response{} = resp) do
    if resp
       |> Req.Response.get_header("content-type")
       |> Enum.any?(
         &(String.contains?(&1, "ndjson") or String.starts_with?(&1, "application/json"))
       ),
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

  # Req decodes JSON responses it recognises; a body it left as a string is
  # decoded here. A decision response is always a JSON object.
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, {:invalid_response, body}}
    end
  end

  defp decode_body(body), do: {:error, {:invalid_response, body}}

  defp try_decode_json(binary) do
    case JSON.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> binary
    end
  end
end
