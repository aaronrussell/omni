defmodule Omni.CodecTest do
  use ExUnit.Case, async: true

  alias Omni.{Codec, Message, Usage}
  alias Omni.Content.{Attachment, Text, Thinking, ToolResult, ToolUse}

  describe "encode/1 and decode/1 — Text" do
    test "round-trips a basic text block" do
      text = %Text{text: "hello"}
      encoded = Codec.encode(text)

      assert encoded == %{"__type" => "Text", "text" => "hello"}
      assert {:ok, ^text} = Codec.decode(encoded)
    end

    test "round-trips with signature" do
      text = %Text{text: "hello", signature: "sig123"}
      encoded = Codec.encode(text)

      assert encoded["signature"] == "sig123"
      assert {:ok, ^text} = Codec.decode(encoded)
    end

    test "omits nil signature on encode" do
      encoded = Codec.encode(%Text{text: "hi"})
      refute Map.has_key?(encoded, "signature")
    end
  end

  describe "encode/1 and decode/1 — Thinking" do
    test "round-trips a thinking block with text" do
      block = %Thinking{text: "let me think...", signature: "sig"}
      encoded = Codec.encode(block)

      assert encoded["text"] == "let me think..."
      assert {:ok, ^block} = Codec.decode(encoded)
    end

    test "round-trips a redacted thinking block (text is nil)" do
      block = %Thinking{text: nil, redacted_data: "encrypted_blob", signature: "sig"}
      encoded = Codec.encode(block)

      refute Map.has_key?(encoded, "text")
      assert encoded["redacted_data"] == "encrypted_blob"
      assert {:ok, ^block} = Codec.decode(encoded)
    end

    test "round-trips an empty thinking block" do
      block = %Thinking{}
      encoded = Codec.encode(block)

      assert encoded == %{"__type" => "Thinking"}
      assert {:ok, ^block} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — Attachment" do
    test "round-trips a base64 source" do
      attachment = %Attachment{
        source: {:base64, "abc=="},
        media_type: "image/png"
      }

      encoded = Codec.encode(attachment)

      assert encoded["source"] == %{"type" => "base64", "data" => "abc=="}
      assert {:ok, ^attachment} = Codec.decode(encoded)
    end

    test "round-trips a url source" do
      attachment = %Attachment{
        source: {:url, "https://example.com/x.png"},
        media_type: "image/png"
      }

      encoded = Codec.encode(attachment)

      assert encoded["source"] == %{"type" => "url", "url" => "https://example.com/x.png"}
      assert {:ok, ^attachment} = Codec.decode(encoded)
    end

    test "omits empty meta from encoded output" do
      attachment = %Attachment{source: {:url, "https://x"}, media_type: "image/png"}
      encoded = Codec.encode(attachment)

      refute Map.has_key?(encoded, "meta")
      assert {:ok, %Attachment{meta: %{}}} = Codec.decode(encoded)
    end

    test "round-trips populated meta with mixed-key map" do
      attachment = %Attachment{
        source: {:url, "https://x"},
        media_type: "image/png",
        meta: %{:filename => "cat.png", "label" => "Cat"}
      }

      encoded = Codec.encode(attachment)

      assert %{"__etf" => blob} = encoded["meta"]
      assert is_binary(blob)
      assert {:ok, ^attachment} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — ToolUse" do
    test "round-trips a tool use" do
      tool_use = %ToolUse{
        id: "call_1",
        name: "get_weather",
        input: %{"city" => "London", "units" => "celsius"}
      }

      encoded = Codec.encode(tool_use)

      assert encoded["input"] == %{"city" => "London", "units" => "celsius"}
      assert {:ok, ^tool_use} = Codec.decode(encoded)
    end

    test "round-trips with signature" do
      tool_use = %ToolUse{id: "x", name: "y", input: %{}, signature: "sig"}
      encoded = Codec.encode(tool_use)

      assert {:ok, ^tool_use} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — ToolResult" do
    test "round-trips with text content" do
      result = %ToolResult{
        tool_use_id: "call_1",
        name: "get_weather",
        content: [%Text{text: "21°C"}],
        is_error: false
      }

      encoded = Codec.encode(result)

      assert {:ok, ^result} = Codec.decode(encoded)
    end

    test "round-trips with mixed text and attachment content" do
      result = %ToolResult{
        tool_use_id: "call_1",
        name: "screenshot",
        content: [
          %Text{text: "see image"},
          %Attachment{source: {:base64, "PNG..."}, media_type: "image/png"}
        ],
        is_error: false
      }

      encoded = Codec.encode(result)

      assert {:ok, ^result} = Codec.decode(encoded)
    end

    test "round-trips an error result" do
      result = %ToolResult{
        tool_use_id: "call_1",
        name: "get_weather",
        content: [%Text{text: "API failed"}],
        is_error: true
      }

      encoded = Codec.encode(result)
      assert encoded["is_error"] == true
      assert {:ok, ^result} = Codec.decode(encoded)
    end

    test "defaults content and is_error when absent on decode" do
      encoded = %{"__type" => "ToolResult", "tool_use_id" => "x", "name" => "y"}
      assert {:ok, %ToolResult{content: [], is_error: false}} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — Usage" do
    test "round-trips a usage struct with all fields" do
      usage = %Usage{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 10,
        cache_write_tokens: 5,
        total_tokens: 165,
        input_cost: 0.001,
        output_cost: 0.002,
        cache_read_cost: 0.0001,
        cache_write_cost: 0.0002,
        total_cost: 0.0033
      }

      encoded = Codec.encode(usage)

      assert {:ok, ^usage} = Codec.decode(encoded)
    end

    test "round-trips defaults" do
      usage = %Usage{}
      encoded = Codec.encode(usage)

      assert {:ok, ^usage} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — Message" do
    test "round-trips a simple user message" do
      msg = Message.new("hello")
      encoded = Codec.encode(msg)

      assert encoded["role"] == "user"
      assert encoded["timestamp"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert {:ok, decoded} = Codec.decode(encoded)
      assert decoded.role == :user
      assert decoded.content == msg.content
      assert decoded.timestamp == msg.timestamp
      assert decoded.private == %{}
    end

    test "round-trips an assistant message with mixed content" do
      msg = %Message{
        role: :assistant,
        content: [
          %Thinking{text: "considering..."},
          %Text{text: "the answer is 42"},
          %ToolUse{id: "x", name: "calc", input: %{"a" => 1}}
        ],
        timestamp: ~U[2025-06-01 12:00:00Z]
      }

      encoded = Codec.encode(msg)
      assert {:ok, ^msg} = Codec.decode(encoded)
    end

    test "omits empty private from encoded output" do
      msg = Message.new("hi")
      encoded = Codec.encode(msg)
      refute Map.has_key?(encoded, "private")
    end

    test "round-trips populated private with atoms, tuples, and atom keys" do
      msg = %Message{
        role: :assistant,
        content: [%Text{text: "hi"}],
        timestamp: ~U[2025-01-01 00:00:00Z],
        private: %{
          reasoning_details: [%{type: :summary, text: "x"}],
          extra: {:tagged, 1, "two"}
        }
      }

      encoded = Codec.encode(msg)
      assert %{"__etf" => _} = encoded["private"]
      assert {:ok, ^msg} = Codec.decode(encoded)
    end
  end

  describe "encode/1 and decode/1 — lists" do
    test "round-trips a list of messages" do
      msgs = [
        Message.new("hi"),
        %Message{role: :assistant, content: [%Text{text: "hello"}], timestamp: DateTime.utc_now()}
      ]

      encoded = Codec.encode(msgs)

      assert is_list(encoded)
      assert length(encoded) == 2
      assert {:ok, ^msgs} = Codec.decode(encoded)
    end

    test "round-trips a mixed list" do
      items = [
        %Text{text: "a"},
        %Usage{input_tokens: 5},
        %ToolUse{id: "x", name: "y", input: %{}}
      ]

      encoded = Codec.encode(items)

      assert {:ok, ^items} = Codec.decode(encoded)
    end

    test "round-trips an empty list" do
      assert Codec.encode([]) == []
      assert Codec.decode([]) == {:ok, []}
    end
  end

  describe "decode/1 — error cases" do
    test "rejects non-map, non-list input" do
      assert Codec.decode("nope") == {:error, :invalid_input}
      assert Codec.decode(42) == {:error, :invalid_input}
      assert Codec.decode(nil) == {:error, :invalid_input}
    end

    test "rejects map without __type" do
      assert Codec.decode(%{"role" => "user"}) == {:error, :invalid_input}
    end

    test "rejects unknown __type" do
      assert Codec.decode(%{"__type" => "Bogus"}) == {:error, {:unknown_type, "Bogus"}}
    end

    test "rejects invalid role" do
      encoded = %{
        "__type" => "Message",
        "role" => "system",
        "content" => [],
        "timestamp" => "2025-01-01T00:00:00Z"
      }

      assert Codec.decode(encoded) == {:error, {:invalid_role, "system"}}
    end

    test "rejects missing required field" do
      assert Codec.decode(%{"__type" => "Text"}) == {:error, {:missing_field, :text}}

      assert Codec.decode(%{"__type" => "ToolUse", "id" => "x"}) ==
               {:error, {:missing_field, :name}}
    end

    test "rejects invalid attachment source" do
      encoded = %{
        "__type" => "Attachment",
        "source" => %{"type" => "ftp", "url" => "ftp://x"},
        "media_type" => "image/png"
      }

      assert {:error, {:invalid_source, _}} = Codec.decode(encoded)
    end

    test "rejects invalid timestamp" do
      encoded = %{
        "__type" => "Message",
        "role" => "user",
        "content" => [],
        "timestamp" => "not-a-date"
      }

      assert {:error, {:invalid_timestamp, _}} = Codec.decode(encoded)
    end

    test "rejects invalid ETF blob" do
      encoded = %{
        "__type" => "Message",
        "role" => "user",
        "content" => [],
        "timestamp" => "2025-01-01T00:00:00Z",
        "private" => %{"__etf" => "not-base64-!!!"}
      }

      assert {:error, {:invalid_etf, _}} = Codec.decode(encoded)
    end

    test "rejects malformed ETF wrapper" do
      encoded = %{
        "__type" => "Attachment",
        "source" => %{"type" => "url", "url" => "x"},
        "media_type" => "image/png",
        "meta" => %{"not_etf" => "wat"}
      }

      assert {:error, {:invalid_etf, _}} = Codec.decode(encoded)
    end

    test "decode of list halts on first failing element" do
      items = [
        Codec.encode(%Text{text: "ok"}),
        %{"__type" => "Bogus"}
      ]

      assert Codec.decode(items) == {:error, {:unknown_type, "Bogus"}}
    end
  end

  describe "encode_term/1 and decode_term/1" do
    test "round-trips a tuple" do
      wrapper = Codec.encode_term({:ok, 1, "two"})
      assert %{"__etf" => blob} = wrapper
      assert is_binary(blob)
      assert {:ok, {:ok, 1, "two"}} = Codec.decode_term(wrapper)
    end

    test "round-trips an atom-keyed map" do
      term = %{foo: :bar, nested: %{count: 3}}
      assert {:ok, ^term} = term |> Codec.encode_term() |> Codec.decode_term()
    end

    test "round-trips a struct" do
      term = ~U[2025-01-01 00:00:00Z]
      assert {:ok, ^term} = term |> Codec.encode_term() |> Codec.decode_term()
    end

    test "round-trips empty containers and primitives" do
      for term <- [%{}, [], "", 0, nil, true, :ok] do
        assert {:ok, ^term} = term |> Codec.encode_term() |> Codec.decode_term()
      end
    end

    test "decode_term rejects malformed wrapper" do
      assert {:error, {:invalid_etf, _}} = Codec.decode_term(%{"foo" => "bar"})
      assert {:error, {:invalid_etf, _}} = Codec.decode_term("nope")
    end

    test "decode_term rejects bad base64" do
      assert {:error, {:invalid_etf, :base64}} = Codec.decode_term(%{"__etf" => "!!!"})
    end

    test "decode_term rejects bad ETF binary" do
      bogus = Base.encode64("not a real ETF binary")
      assert {:error, {:invalid_etf, _}} = Codec.decode_term(%{"__etf" => bogus})
    end

    test "encode_term output survives a JSON round-trip" do
      term = %{tagged: {:ok, [1, 2, 3]}, when: ~U[2025-01-01 00:00:00Z]}
      json = term |> Codec.encode_term() |> JSON.encode!()
      assert {:ok, ^term} = json |> JSON.decode!() |> Codec.decode_term()
    end
  end

  describe "encode/1 produces JSON-safe output" do
    test "Message with full content survives JSON round-trip" do
      msg = %Message{
        role: :assistant,
        content: [
          %Text{text: "answer"},
          %ToolUse{id: "1", name: "fn", input: %{"a" => 1}}
        ],
        timestamp: ~U[2025-01-01 00:00:00Z],
        private: %{foo: :bar}
      }

      encoded = Codec.encode(msg)
      json = JSON.encode!(encoded)
      decoded_json = JSON.decode!(json)

      assert {:ok, ^msg} = Codec.decode(decoded_json)
    end
  end
end
