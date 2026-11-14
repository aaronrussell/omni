defmodule Omni.Codec do
  @moduledoc """
  Lossless serialisation of Omni structs to and from JSON-safe maps.

  Use this when persisting messages, content blocks, usage records or
  decisions to a storage layer that speaks JSON (Ecto `:map` columns,
  document stores, the wire). `encode/1` produces a plain map (or list of
  maps) with string keys and only JSON-compatible values; `decode/2`
  reverses it, returning the original structs.

  The encoded shape is self-describing — every encoded value carries a
  `"__type"` discriminator so `decode/2` can dispatch without external
  context.

  ## Supported types

  - `Omni.Message`
  - `Omni.Content.Text`, `Omni.Content.Thinking`, `Omni.Content.Attachment`,
    `Omni.Content.ToolUse`, `Omni.Content.ToolResult`, `Omni.Content.Data`
  - `Omni.Usage`
  - `Omni.Decision`, the `Omni.Question` structs and the `Omni.Answer`
    structs

  Lists of any combination of the above are also supported. Keyword lists
  (a decision's questions or answers) are encoded only inside a decision.

  ## Message origin

  `Message.origin` is encoded readably, as `%{"model" => "provider:model",
  "dialect" => "Omni.Dialects.AnthropicMessages"}`, the model a string
  reference (see `Omni.Model`). A provider that isn't loaded, or a dialect
  unknown to the decoding node, decodes as `nil`, so that message's thinking
  is not sent back.

  ## Decisions

  A decision is encoded whole: state, questions, and once answered its
  answers, usage and model.

  - `:model` is stored as a string reference (`"openai:gpt-6-luna"`) and
    looked up when decoding, so the decoded decision holds the model as it
    is loaded now. A model that isn't loaded decodes as `nil`.
  - `:raw` is not encoded and decodes as `nil`.
  - Questions and answers are lists of `%{"name" => ..., "question" => ...}`
    (or `"answer"`) maps in order. Choices, levels, probabilities and
    criteria are lists of `[key, value]` pairs, so order survives stores
    that reorder object keys.
  - Choice and level keys keep their type: a string key is a JSON string,
    an atom key `%{"atom" => "billing"}`. Question names are always atoms
    and are stored as plain strings.

  ## Atoms

  By default decoding never creates atoms, so it is safe on input you don't
  control: question names and atom keys must already exist on the decoding
  node (`{:error, {:unknown_atom, name}}` otherwise), and opaque blobs are
  read with `:erlang.binary_to_term/2`'s `:safe` option, failing with
  `{:error, {:invalid_etf, _}}` on an unknown atom.

  An atom exists once a module that mentions it is loaded. A release loads
  every module at boot, but in development modules load on first use, and
  atoms built at runtime (`:"record_\#{id}"`) don't exist on a fresh node.
  When decoding data your app wrote itself, pass `atoms: :create` to create
  them, for decision keys and opaque blobs alike:

  ```elixir
  Omni.Codec.decode(stored, atoms: :create)
  ```

  Never pass it for untrusted input: atoms are not garbage-collected, and
  enough distinct ones crash the node.

  ## Opaque fields

  `Message.private` and `Attachment.meta` can hold arbitrary terms (atoms,
  tuples, structs from provider-specific data) that have no portable JSON
  representation. These are encoded as opaque base64-encoded ETF blobs
  (`%{"__etf" => "..."}`), decoded as described under [Atoms](#module-atoms).

  ## Encoding arbitrary terms

  `encode_term/1` and `decode_term/2` expose the same opaque-blob mechanism
  for any Erlang term. Use them in persistence layers that need to stash
  values outside the Omni struct family while keeping the same JSON-safe
  shape.

  ## Examples

  ```elixir
  iex> message = Omni.Message.new("hello")
  iex> encoded = Omni.Codec.encode(message)
  iex> {:ok, ^message} = Omni.Codec.decode(encoded)
  ```
  """

  alias Omni.{Answer, Decision, Message, Model, Question, Usage, Util}
  alias Omni.Content.{Attachment, Data, Text, Thinking, ToolResult, ToolUse}

  import Util, only: [maybe_put: 3]

  @typedoc "Any value the codec can encode."
  @type encodable ::
          Message.t()
          | Text.t()
          | Thinking.t()
          | Attachment.t()
          | ToolUse.t()
          | ToolResult.t()
          | Data.t()
          | Usage.t()
          | Decision.t()
          | Question.t()
          | Answer.t()

  @typedoc "Decode error reasons."
  @type error ::
          :invalid_input
          | {:unknown_type, String.t()}
          | {:invalid_role, term()}
          | {:missing_field, atom()}
          | {:invalid_field, atom()}
          | {:invalid_key, term()}
          | {:unknown_atom, String.t()}
          | {:invalid_source, term()}
          | {:invalid_timestamp, term()}
          | {:invalid_etf, term()}

  @typedoc "Decode options (see `decode/2`)."
  @type decode_opts :: [atoms: :existing | :create]

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
  def encode(%Data{} = d), do: %{"__type" => "Data", "data" => d.data}
  def encode(%Usage{} = u), do: encode_usage(u)
  def encode(%Decision{} = d), do: encode_decision(d)
  def encode(%Question.Predicate{} = q), do: encode_predicate_question(q)
  def encode(%Question.Choice{} = q), do: encode_choice_question(q)
  def encode(%Question.Score{} = q), do: encode_score_question(q)
  def encode(%Answer.Predicate{} = a), do: encode_predicate_answer(a)
  def encode(%Answer.Choice{} = a), do: encode_choice_answer(a)
  def encode(%Answer.Score{} = a), do: encode_score_answer(a)
  def encode(%Answer.Refusal{}), do: %{"__type" => "Answer.Refusal"}

  @doc """
  Decodes a previously-encoded map (or list of maps) back into Omni structs.

  Returns `{:ok, struct}` or `{:ok, [struct, ...]}` on success. Returns
  `{:error, reason}` if the input is malformed, has an unknown `"__type"`,
  or fails field-level validation. For lists, decoding stops on the first
  failing element.

  ## Options

  - `:atoms` - `:existing` (default) decodes only atoms that already
    exist on this node; `:create` creates them, for data your app wrote
    itself (see [Atoms](#module-atoms))
  """
  @spec decode(map() | [map()], decode_opts()) :: {:ok, term()} | {:error, error()}
  def decode(input, opts \\ []), do: do_decode(input, atoms_mode(opts))

  @doc """
  Encodes an arbitrary Erlang term as an opaque JSON-safe wrapper.

  The term is serialised via `:erlang.term_to_binary/1` and base64-encoded
  inside a `%{"__etf" => "..."}` map. Use this for values that have no
  portable JSON representation (atom-keyed maps, tuples, structs) when you
  need to stash them in a JSON-typed storage column.

  ```elixir
  iex> wrapper = Omni.Codec.encode_term({:ok, %{a: 1}})
  iex> {:ok, {:ok, %{a: 1}}} = Omni.Codec.decode_term(wrapper)
  ```
  """
  @spec encode_term(term()) :: %{String.t() => String.t()}
  def encode_term(term) do
    %{"__etf" => term |> :erlang.term_to_binary() |> Base.encode64()}
  end

  @doc """
  Decodes a wrapper produced by `encode_term/1` back into the original term.

  By default uses `:erlang.binary_to_term/2` with the `:safe` option, so
  unknown atoms are not created and code is not loaded from the binary.
  Takes the same `:atoms` option as `decode/2`; `atoms: :create` drops
  `:safe`, for data your app wrote itself.
  """
  @spec decode_term(map(), decode_opts()) :: {:ok, term()} | {:error, error()}
  def decode_term(wrapper, opts \\ []), do: decode_blob(wrapper, atoms_mode(opts))

  defp atoms_mode(opts) do
    case Keyword.get(opts, :atoms, :existing) do
      mode when mode in [:existing, :create] ->
        mode

      other ->
        raise ArgumentError, "expected :atoms to be :existing or :create, got: #{inspect(other)}"
    end
  end

  # Encoders

  defp encode_message(%Message{} = m) do
    %{
      "__type" => "Message",
      "role" => Atom.to_string(m.role),
      "content" => Enum.map(m.content, &encode/1),
      "timestamp" => DateTime.to_iso8601(m.timestamp)
    }
    |> maybe_put("origin", encode_origin(m.origin))
    |> maybe_put("private", encode_etf(m.private))
  end

  defp encode_origin(nil), do: nil

  defp encode_origin(%{model: ref, dialect: dialect}) do
    %{"model" => Model.to_ref(ref, :colon), "dialect" => inspect(dialect)}
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
    |> maybe_put("id", t.id)
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

  # `raw` holds Req structs (with the request's auth header), so it is left out.
  defp encode_decision(%Decision{} = d) do
    %{
      "__type" => "Decision",
      "state" => encode(d.state),
      "questions" => encode_named(d.questions, "question")
    }
    |> maybe_put("answers", d.answers && encode_named(d.answers, "answer"))
    |> maybe_put("usage", d.usage && encode(d.usage))
    |> maybe_put("model", d.model && Model.to_ref(d.model, :colon))
  end

  defp encode_named(list, field) do
    Enum.map(list, fn {name, value} ->
      %{"name" => Atom.to_string(name), field => encode(value)}
    end)
  end

  defp encode_predicate_question(%Question.Predicate{} = q) do
    %{"__type" => "Question.Predicate", "instructions" => encode(q.instructions)}
    |> maybe_put("criteria", q.criteria && Enum.map(q.criteria, fn {k, v} -> [k, v] end))
  end

  defp encode_choice_question(%Question.Choice{} = q) do
    %{
      "__type" => "Question.Choice",
      "instructions" => encode(q.instructions),
      "choices" => encode_pairs(q.choices)
    }
  end

  defp encode_score_question(%Question.Score{} = q) do
    %{
      "__type" => "Question.Score",
      "instructions" => encode(q.instructions),
      "levels" => encode_pairs(q.levels)
    }
  end

  defp encode_predicate_answer(%Answer.Predicate{} = a) do
    %{"__type" => "Answer.Predicate", "probability" => a.probability}
  end

  defp encode_choice_answer(%Answer.Choice{} = a) do
    %{
      "__type" => "Answer.Choice",
      "choice" => encode_key(a.choice),
      "probabilities" => encode_pairs(a.probabilities)
    }
    |> maybe_put("confidence", a.confidence)
  end

  defp encode_score_answer(%Answer.Score{} = a) do
    %{
      "__type" => "Answer.Score",
      "score" => a.score,
      "probabilities" => encode_pairs(a.probabilities)
    }
    |> maybe_put("confidence", a.confidence)
  end

  # `{key, value}` pairs with a choice or level key, as `[key, value]`.
  defp encode_pairs(pairs), do: Enum.map(pairs, fn {key, value} -> [encode_key(key), value] end)

  defp encode_key(key) when is_atom(key), do: %{"atom" => Atom.to_string(key)}
  defp encode_key(key) when is_binary(key), do: key

  defp encode_source({:base64, data}), do: %{"type" => "base64", "data" => data}
  defp encode_source({:url, url}), do: %{"type" => "url", "url" => url}

  defp encode_etf(value) when value == %{}, do: nil
  defp encode_etf(value) when is_map(value), do: encode_term(value)

  # Decoders

  defp do_decode(list, mode) when is_list(list), do: decode_list(list, mode)
  defp do_decode(%{"__type" => type} = map, mode), do: decode_by_type(type, map, mode)
  defp do_decode(_input, _mode), do: {:error, :invalid_input}

  defp decode_list(list, mode) when is_list(list), do: map_ok(list, &do_decode(&1, mode))
  defp decode_list(_other, _mode), do: {:error, :invalid_input}

  defp decode_by_type("Message", map, mode), do: decode_message(map, mode)
  defp decode_by_type("Text", map, _mode), do: decode_text(map)
  defp decode_by_type("Thinking", map, _mode), do: decode_thinking(map)
  defp decode_by_type("Attachment", map, mode), do: decode_attachment(map, mode)
  defp decode_by_type("ToolUse", map, _mode), do: decode_tool_use(map)
  defp decode_by_type("ToolResult", map, mode), do: decode_tool_result(map, mode)
  defp decode_by_type("Data", map, _mode), do: decode_data(map)
  defp decode_by_type("Usage", map, _mode), do: decode_usage(map)
  defp decode_by_type("Decision", map, mode), do: decode_decision(map, mode)
  defp decode_by_type("Question.Predicate", map, mode), do: decode_predicate_question(map, mode)
  defp decode_by_type("Question.Choice", map, mode), do: decode_choice_question(map, mode)
  defp decode_by_type("Question.Score", map, mode), do: decode_score_question(map, mode)
  defp decode_by_type("Answer.Predicate", map, _mode), do: decode_predicate_answer(map)
  defp decode_by_type("Answer.Choice", map, mode), do: decode_choice_answer(map, mode)
  defp decode_by_type("Answer.Score", map, mode), do: decode_score_answer(map, mode)
  defp decode_by_type("Answer.Refusal", _map, _mode), do: {:ok, %Answer.Refusal{}}
  defp decode_by_type(other, _map, _mode), do: {:error, {:unknown_type, other}}

  defp decode_message(map, mode) do
    with {:ok, role} <- decode_role(Map.get(map, "role")),
         {:ok, content_raw} <- require_field(map, "content"),
         {:ok, content} <- decode_list(content_raw, mode),
         {:ok, ts_raw} <- require_field(map, "timestamp"),
         {:ok, timestamp} <- decode_timestamp(ts_raw),
         {:ok, private} <- decode_etf(Map.get(map, "private"), mode) do
      {:ok,
       %Message{
         role: role,
         content: content,
         timestamp: timestamp,
         origin: decode_origin(Map.get(map, "origin")),
         private: private
       }}
    end
  end

  # A provider that isn't loaded, or a dialect this node doesn't know, decodes
  # as no origin, which only means the message's thinking isn't sent back.
  defp decode_origin(%{"model" => ref, "dialect" => dialect})
       when is_binary(ref) and is_binary(dialect) do
    case Model.parse_ref(ref) do
      {:ok, ref} -> %{model: ref, dialect: String.to_existing_atom("Elixir." <> dialect)}
      {:error, _} -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp decode_origin(_), do: nil

  defp decode_text(map) do
    with {:ok, text} <- require_field(map, "text") do
      {:ok, %Text{text: text, signature: Map.get(map, "signature")}}
    end
  end

  # `data` was normalised through JSON by `Data.new/1`, so it is stored as is.
  defp decode_data(map) do
    with {:ok, data} <- require_field(map, "data"), do: {:ok, %Data{data: data}}
  end

  defp decode_thinking(map) do
    {:ok,
     %Thinking{
       text: Map.get(map, "text"),
       signature: Map.get(map, "signature"),
       redacted_data: Map.get(map, "redacted_data"),
       id: Map.get(map, "id")
     }}
  end

  defp decode_attachment(map, mode) do
    with {:ok, source_raw} <- require_field(map, "source"),
         {:ok, source} <- decode_source(source_raw),
         {:ok, media_type} <- require_field(map, "media_type"),
         {:ok, meta} <- decode_etf(Map.get(map, "meta"), mode) do
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

  defp decode_tool_result(map, mode) do
    with {:ok, tool_use_id} <- require_field(map, "tool_use_id"),
         {:ok, name} <- require_field(map, "name"),
         content_raw = Map.get(map, "content", []),
         {:ok, content} <- decode_list(content_raw, mode) do
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

  defp decode_decision(map, mode) do
    with {:ok, state_raw} <- require_field(map, "state"),
         {:ok, state} <- decode_list(state_raw, mode),
         {:ok, questions_raw} <- require_field(map, "questions"),
         {:ok, questions} <- decode_named(questions_raw, :questions, "question", mode),
         {:ok, answers} <-
           decode_optional(map["answers"], &decode_named(&1, :answers, "answer", mode)),
         {:ok, usage} <- decode_optional(map["usage"], &do_decode(&1, mode)) do
      {:ok,
       %Decision{
         state: state,
         questions: questions,
         answers: answers,
         usage: usage,
         model: decode_model(map["model"])
       }}
    end
  end

  defp decode_named(list, field, key, mode) when is_list(list) do
    map_ok(list, fn
      %{"name" => name} = item when is_binary(name) ->
        with {:ok, name} <- decode_atom(name, mode),
             {:ok, raw} <- require_field(item, key),
             {:ok, value} <- do_decode(raw, mode),
             do: {:ok, {name, value}}

      _item ->
        {:error, {:invalid_field, field}}
    end)
  end

  defp decode_named(_other, field, _key, _mode), do: {:error, {:invalid_field, field}}

  # A model that isn't loaded decodes as nil, as an origin does.
  defp decode_model(ref) when is_binary(ref) do
    case Model.get(ref) do
      {:ok, model} -> model
      {:error, _} -> nil
    end
  end

  defp decode_model(_ref), do: nil

  defp decode_predicate_question(map, mode) do
    with {:ok, instructions} <- decode_instructions(map, mode),
         {:ok, criteria} <- decode_optional(map["criteria"], &decode_criteria/1) do
      {:ok, %Question.Predicate{instructions: instructions, criteria: criteria}}
    end
  end

  defp decode_choice_question(map, mode) do
    with {:ok, instructions} <- decode_instructions(map, mode),
         {:ok, raw} <- require_field(map, "choices"),
         {:ok, choices} <- decode_pairs(raw, :choices, mode) do
      {:ok, %Question.Choice{instructions: instructions, choices: choices}}
    end
  end

  defp decode_score_question(map, mode) do
    with {:ok, instructions} <- decode_instructions(map, mode),
         {:ok, raw} <- require_field(map, "levels"),
         {:ok, levels} <- decode_pairs(raw, :levels, mode) do
      {:ok, %Question.Score{instructions: instructions, levels: levels}}
    end
  end

  defp decode_instructions(map, mode) do
    with {:ok, raw} <- require_field(map, "instructions"), do: decode_list(raw, mode)
  end

  defp decode_criteria(list) when is_list(list) do
    map_ok(list, fn
      [key, text] when is_boolean(key) -> {:ok, {key, text}}
      _pair -> {:error, {:invalid_field, :criteria}}
    end)
  end

  defp decode_criteria(_other), do: {:error, {:invalid_field, :criteria}}

  defp decode_predicate_answer(map) do
    with {:ok, probability} <- require_field(map, "probability") do
      {:ok, %Answer.Predicate{probability: probability}}
    end
  end

  defp decode_choice_answer(map, mode) do
    with {:ok, choice_raw} <- require_field(map, "choice"),
         {:ok, choice} <- decode_key(choice_raw, mode),
         {:ok, raw} <- require_field(map, "probabilities"),
         {:ok, probabilities} <- decode_pairs(raw, :probabilities, mode) do
      {:ok,
       %Answer.Choice{
         choice: choice,
         probabilities: probabilities,
         confidence: map["confidence"]
       }}
    end
  end

  defp decode_score_answer(map, mode) do
    with {:ok, score} <- require_field(map, "score"),
         {:ok, raw} <- require_field(map, "probabilities"),
         {:ok, probabilities} <- decode_pairs(raw, :probabilities, mode) do
      {:ok,
       %Answer.Score{score: score, probabilities: probabilities, confidence: map["confidence"]}}
    end
  end

  # `[key, value]` pairs with a choice or level key, as `{key, value}`.
  defp decode_pairs(list, field, mode) when is_list(list) do
    map_ok(list, fn
      [key, value] -> with {:ok, key} <- decode_key(key, mode), do: {:ok, {key, value}}
      _pair -> {:error, {:invalid_field, field}}
    end)
  end

  defp decode_pairs(_other, field, _mode), do: {:error, {:invalid_field, field}}

  defp decode_key(key, _mode) when is_binary(key), do: {:ok, key}
  defp decode_key(%{"atom" => name}, mode) when is_binary(name), do: decode_atom(name, mode)
  defp decode_key(other, _mode), do: {:error, {:invalid_key, other}}

  defp decode_atom(name, :create), do: {:ok, String.to_atom(name)}

  defp decode_atom(name, :existing) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, name}}
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

  defp decode_etf(nil, _mode), do: {:ok, %{}}
  defp decode_etf(value, mode), do: decode_blob(value, mode)

  defp decode_blob(%{"__etf" => blob}, mode) when is_binary(blob) do
    with {:ok, bin} <- decode_base64(blob), do: binary_to_term(bin, mode)
  end

  defp decode_blob(other, _mode), do: {:error, {:invalid_etf, other}}

  defp decode_base64(blob) do
    case Base.decode64(blob) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:invalid_etf, :base64}}
    end
  end

  defp binary_to_term(bin, mode) do
    opts = if mode == :existing, do: [:safe], else: []
    {:ok, :erlang.binary_to_term(bin, opts)}
  rescue
    e -> {:error, {:invalid_etf, e}}
  end

  defp decode_optional(nil, _decode), do: {:ok, nil}
  defp decode_optional(value, decode), do: decode.(value)

  # Maps `fun` over `list`, stopping at the first error.
  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp require_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, String.to_atom(key)}}
    end
  end
end
