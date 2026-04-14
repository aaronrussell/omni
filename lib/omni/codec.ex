defmodule Omni.Codec do
  @moduledoc """
  Lossless serialisation of Omni structs to and from JSON-safe maps.

  Use this when persisting messages, content blocks, or usage records to a
  storage layer that speaks JSON (Ecto `:map` columns, document stores, the
  wire). `encode/1` produces a plain map (or list of maps) with string keys
  and only JSON-compatible values; `decode/1` reverses it, returning the
  original structs.

  The encoded shape is self-describing — every encoded value carries a
  `"__type"` discriminator so `decode/1` can dispatch without external
  context.

  ## Supported types

    * `Omni.Message`
    * `Omni.Content.Text`, `Omni.Content.Thinking`, `Omni.Content.Attachment`,
      `Omni.Content.ToolUse`, `Omni.Content.ToolResult`
    * `Omni.Usage`

  Lists of any combination of the above are also supported.

  ## Opaque fields

  `Message.private` and `Attachment.meta` can hold arbitrary terms (atoms,
  tuples, structs from provider-specific data) that have no portable JSON
  representation. These are encoded as opaque base64-encoded ETF blobs
  (`%{"__etf" => "..."}`) and decoded with the `:safe` option, which refuses
  to create new atoms or load resources.

  ## Encoding arbitrary terms

  `encode_term/1` and `decode_term/1` expose the same opaque-blob mechanism
  for any Erlang term. Use them in persistence layers that need to stash
  values outside the Omni struct family while keeping the same JSON-safe
  shape.

  ## Examples

      iex> message = Omni.Message.new("hello")
      iex> encoded = Omni.Codec.encode(message)
      iex> {:ok, ^message} = Omni.Codec.decode(encoded)
  """

  alias Omni.{Message, Usage, Util}
  alias Omni.Content.{Attachment, Text, Thinking, ToolResult, ToolUse}

  import Util, only: [maybe_put: 3]

  @typedoc "Any value the codec can encode."
  @type encodable ::
          Message.t()
          | Text.t()
          | Thinking.t()
          | Attachment.t()
          | ToolUse.t()
          | ToolResult.t()
          | Usage.t()

  @typedoc "Decode error reasons."
  @type error ::
          :invalid_input
          | {:unknown_type, String.t()}
          | {:invalid_role, term()}
          | {:missing_field, atom()}
          | {:invalid_source, term()}
          | {:invalid_timestamp, term()}
          | {:invalid_etf, term()}

  @doc """
  Encodes an Omni struct (or a list of structs) to a JSON-safe map.

  Always succeeds for valid input types. Lists are encoded element-wise and
  returned as a bare list (no envelope).
  """
  @spec encode(encodable() | [encodable()]) :: map() | [map()]
  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(%Message{} = m), do: encode_message(m)
  def encode(%Text{} = t), do: encode_text(t)
  def encode(%Thinking{} = t), do: encode_thinking(t)
  def encode(%Attachment{} = a), do: encode_attachment(a)
  def encode(%ToolUse{} = t), do: encode_tool_use(t)
  def encode(%ToolResult{} = t), do: encode_tool_result(t)
  def encode(%Usage{} = u), do: encode_usage(u)

  @doc """
  Decodes a previously-encoded map (or list of maps) back into Omni structs.

  Returns `{:ok, struct}` or `{:ok, [struct, ...]}` on success. Returns
  `{:error, reason}` if the input is malformed, has an unknown `"__type"`,
  or fails field-level validation. For lists, decoding stops on the first
  failing element.
  """
  @spec decode(map() | [map()]) :: {:ok, term()} | {:error, error()}
  def decode(list) when is_list(list), do: decode_list(list, [])
  def decode(%{"__type" => type} = map), do: decode_by_type(type, map)
  def decode(_), do: {:error, :invalid_input}

  @doc """
  Encodes an arbitrary Erlang term as an opaque JSON-safe wrapper.

  The term is serialised via `:erlang.term_to_binary/1` and base64-encoded
  inside a `%{"__etf" => "..."}` map. Use this for values that have no
  portable JSON representation (atom-keyed maps, tuples, structs) when you
  need to stash them in a JSON-typed storage column.

      iex> wrapper = Omni.Codec.encode_term({:ok, %{a: 1}})
      iex> {:ok, {:ok, %{a: 1}}} = Omni.Codec.decode_term(wrapper)
  """
  @spec encode_term(term()) :: %{String.t() => String.t()}
  def encode_term(term) do
    %{"__etf" => term |> :erlang.term_to_binary() |> Base.encode64()}
  end

  @doc """
  Decodes a wrapper produced by `encode_term/1` back into the original term.

  Uses `:erlang.binary_to_term/2` with the `:safe` option, so unknown atoms
  are not created and code is not loaded from the binary.
  """
  @spec decode_term(map()) :: {:ok, term()} | {:error, error()}
  def decode_term(%{"__etf" => blob}) when is_binary(blob) do
    with {:ok, bin} <- decode_base64(blob),
         {:ok, term} <- safe_binary_to_term(bin) do
      {:ok, term}
    end
  end

  def decode_term(other), do: {:error, {:invalid_etf, other}}

  # Encoders

  defp encode_message(%Message{} = m) do
    %{
      "__type" => "Message",
      "role" => Atom.to_string(m.role),
      "content" => Enum.map(m.content, &encode/1),
      "timestamp" => DateTime.to_iso8601(m.timestamp)
    }
    |> maybe_put("private", encode_etf(m.private))
  end

  defp encode_text(%Text{} = t) do
    %{"__type" => "Text", "text" => t.text}
    |> maybe_put("signature", t.signature)
  end

  defp encode_thinking(%Thinking{} = t) do
    %{"__type" => "Thinking"}
    |> maybe_put("text", t.text)
    |> maybe_put("signature", t.signature)
    |> maybe_put("redacted_data", t.redacted_data)
  end

  defp encode_attachment(%Attachment{} = a) do
    %{
      "__type" => "Attachment",
      "source" => encode_source(a.source),
      "media_type" => a.media_type
    }
    |> maybe_put("meta", encode_etf(a.meta))
  end

  defp encode_tool_use(%ToolUse{} = t) do
    %{
      "__type" => "ToolUse",
      "id" => t.id,
      "name" => t.name,
      "input" => t.input
    }
    |> maybe_put("signature", t.signature)
  end

  defp encode_tool_result(%ToolResult{} = t) do
    %{
      "__type" => "ToolResult",
      "tool_use_id" => t.tool_use_id,
      "name" => t.name,
      "content" => Enum.map(t.content || [], &encode/1),
      "is_error" => t.is_error
    }
  end

  defp encode_usage(%Usage{} = u) do
    %{
      "__type" => "Usage",
      "input_tokens" => u.input_tokens,
      "output_tokens" => u.output_tokens,
      "cache_read_tokens" => u.cache_read_tokens,
      "cache_write_tokens" => u.cache_write_tokens,
      "total_tokens" => u.total_tokens,
      "input_cost" => u.input_cost,
      "output_cost" => u.output_cost,
      "cache_read_cost" => u.cache_read_cost,
      "cache_write_cost" => u.cache_write_cost,
      "total_cost" => u.total_cost
    }
  end

  defp encode_source({:base64, data}), do: %{"type" => "base64", "data" => data}
  defp encode_source({:url, url}), do: %{"type" => "url", "url" => url}

  defp encode_etf(value) when value == %{}, do: nil
  defp encode_etf(value) when is_map(value), do: encode_term(value)

  # Decoders

  defp decode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_list([h | t], acc) do
    case decode(h) do
      {:ok, v} -> decode_list(t, [v | acc])
      {:error, _} = err -> err
    end
  end

  defp decode_by_type("Message", map), do: decode_message(map)
  defp decode_by_type("Text", map), do: decode_text(map)
  defp decode_by_type("Thinking", map), do: decode_thinking(map)
  defp decode_by_type("Attachment", map), do: decode_attachment(map)
  defp decode_by_type("ToolUse", map), do: decode_tool_use(map)
  defp decode_by_type("ToolResult", map), do: decode_tool_result(map)
  defp decode_by_type("Usage", map), do: decode_usage(map)
  defp decode_by_type(other, _map), do: {:error, {:unknown_type, other}}

  defp decode_message(map) do
    with {:ok, role} <- decode_role(Map.get(map, "role")),
         {:ok, content_raw} <- require_field(map, "content"),
         {:ok, content} <- decode_list(content_raw, []),
         {:ok, ts_raw} <- require_field(map, "timestamp"),
         {:ok, timestamp} <- decode_timestamp(ts_raw),
         {:ok, private} <- decode_etf(Map.get(map, "private")) do
      {:ok,
       %Message{
         role: role,
         content: content,
         timestamp: timestamp,
         private: private
       }}
    end
  end

  defp decode_text(map) do
    with {:ok, text} <- require_field(map, "text") do
      {:ok, %Text{text: text, signature: Map.get(map, "signature")}}
    end
  end

  defp decode_thinking(map) do
    {:ok,
     %Thinking{
       text: Map.get(map, "text"),
       signature: Map.get(map, "signature"),
       redacted_data: Map.get(map, "redacted_data")
     }}
  end

  defp decode_attachment(map) do
    with {:ok, source_raw} <- require_field(map, "source"),
         {:ok, source} <- decode_source(source_raw),
         {:ok, media_type} <- require_field(map, "media_type"),
         {:ok, meta} <- decode_etf(Map.get(map, "meta")) do
      {:ok, %Attachment{source: source, media_type: media_type, meta: meta}}
    end
  end

  defp decode_tool_use(map) do
    with {:ok, id} <- require_field(map, "id"),
         {:ok, name} <- require_field(map, "name"),
         {:ok, input} <- require_field(map, "input") do
      {:ok,
       %ToolUse{
         id: id,
         name: name,
         input: input,
         signature: Map.get(map, "signature")
       }}
    end
  end

  defp decode_tool_result(map) do
    with {:ok, tool_use_id} <- require_field(map, "tool_use_id"),
         {:ok, name} <- require_field(map, "name"),
         content_raw = Map.get(map, "content", []),
         {:ok, content} <- decode_list(content_raw, []) do
      {:ok,
       %ToolResult{
         tool_use_id: tool_use_id,
         name: name,
         content: content,
         is_error: Map.get(map, "is_error", false)
       }}
    end
  end

  defp decode_usage(map) do
    {:ok,
     %Usage{
       input_tokens: Map.get(map, "input_tokens", 0),
       output_tokens: Map.get(map, "output_tokens", 0),
       cache_read_tokens: Map.get(map, "cache_read_tokens", 0),
       cache_write_tokens: Map.get(map, "cache_write_tokens", 0),
       total_tokens: Map.get(map, "total_tokens", 0),
       input_cost: Map.get(map, "input_cost", 0),
       output_cost: Map.get(map, "output_cost", 0),
       cache_read_cost: Map.get(map, "cache_read_cost", 0),
       cache_write_cost: Map.get(map, "cache_write_cost", 0),
       total_cost: Map.get(map, "total_cost", 0)
     }}
  end

  defp decode_role("user"), do: {:ok, :user}
  defp decode_role("assistant"), do: {:ok, :assistant}
  defp decode_role(other), do: {:error, {:invalid_role, other}}

  defp decode_source(%{"type" => "base64", "data" => data}) when is_binary(data),
    do: {:ok, {:base64, data}}

  defp decode_source(%{"type" => "url", "url" => url}) when is_binary(url),
    do: {:ok, {:url, url}}

  defp decode_source(other), do: {:error, {:invalid_source, other}}

  defp decode_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_timestamp, reason}}
    end
  end

  defp decode_timestamp(other), do: {:error, {:invalid_timestamp, other}}

  defp decode_etf(nil), do: {:ok, %{}}
  defp decode_etf(value), do: decode_term(value)

  defp decode_base64(blob) do
    case Base.decode64(blob) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:invalid_etf, :base64}}
    end
  end

  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    e -> {:error, {:invalid_etf, e}}
  end

  defp require_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, String.to_atom(key)}}
    end
  end
end
