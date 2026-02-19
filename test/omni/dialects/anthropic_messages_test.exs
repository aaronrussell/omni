defmodule Omni.Dialects.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.AnthropicMessages
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Model, Tool}

  @model Model.new(
           id: "claude-sonnet-4-20250514",
           name: "Claude Sonnet 4",
           provider: Omni.Providers.Anthropic,
           dialect: AnthropicMessages,
           max_output_tokens: 8192
         )

  describe "option_schema/0" do
    test "returns empty map" do
      assert AnthropicMessages.option_schema() == %{}
    end
  end

  describe "build_path/1" do
    test "returns /v1/messages" do
      assert AnthropicMessages.build_path(@model) == "/v1/messages"
    end
  end

  describe "build_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["max_tokens"] == 4096
      assert body["stream"] == true
      assert length(body["messages"]) == 1

      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == [%{"type" => "text", "text" => "Hello"}]
    end

    test "system prompt as content block array" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      assert [%{"type" => "text", "text" => "You are helpful."}] = body["system"]
    end

    test "no system prompt omits key" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      refute Map.has_key?(body, "system")
    end

    test "max_tokens in opts overrides default" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, max_tokens: 1024)

      assert body["max_tokens"] == 1024
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, temperature: 0.7)

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, metadata: %{"user_id" => "123"})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      refute Map.has_key?(body, "metadata")
    end

    test "tools in context" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("What's the weather?")], tools: [tool])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["name"] == "get_weather"
      assert encoded_tool["description"] == "Gets the weather"

      assert encoded_tool["input_schema"] == %{
               type: "object",
               properties: %{city: %{type: "string"}}
             }
    end

    test "empty tools omits key" do
      context = Context.new("Hello")
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      assert length(body["messages"]) == 3
      roles = Enum.map(body["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user"]
    end

    test "encodes Text content block" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      assert [%{"content" => [%{"type" => "text", "text" => "Hello"}]}] = body["messages"]
    end

    test "encodes Thinking content block" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: "Let me think...", signature: "sig123")]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "thinking"
      assert block["thinking"] == "Let me think..."
      assert block["signature"] == "sig123"
    end

    test "encodes ToolUse content block" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            ToolUse.new(id: "toolu_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "tool_use"
      assert block["id"] == "toolu_01"
      assert block["name"] == "get_weather"
      assert block["input"] == %{"city" => "London"}
    end

    test "encodes ToolResult content block" do
      msg =
        Message.new(
          role: :user,
          content: [
            ToolResult.new(
              tool_use_id: "toolu_01",
              name: "get_weather",
              content: "Sunny, 22°C",
              is_error: false
            )
          ]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "toolu_01"
      assert block["is_error"] == false
      assert [%{"type" => "text", "text" => "Sunny, 22°C"}] = block["content"]
      refute Map.has_key?(block, "name")
    end

    test "encodes image attachment with base64 source" do
      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, "abc123"}, media_type: "image/png")]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "image"
      assert block["source"]["type"] == "base64"
      assert block["source"]["media_type"] == "image/png"
      assert block["source"]["data"] == "abc123"
    end

    test "encodes image attachment with URL source" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(
              source: {:url, "https://example.com/image.png"},
              media_type: "image/png"
            )
          ]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "image"
      assert block["source"]["type"] == "url"
      assert block["source"]["url"] == "https://example.com/image.png"
    end

    test "encodes PDF attachment with base64 source as document" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "pdf-data"}, media_type: "application/pdf")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "base64"
      assert block["source"]["media_type"] == "application/pdf"
      assert block["source"]["data"] == "pdf-data"
    end

    test "encodes PDF attachment with URL source as document" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(
              source: {:url, "https://example.com/doc.pdf"},
              media_type: "application/pdf"
            )
          ]
        )

      context = Context.new([msg])
      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "url"
      assert block["source"]["url"] == "https://example.com/doc.pdf"
    end

    test "all image media types encode as image" do
      for mt <- ~w(image/jpeg image/png image/gif image/webp) do
        msg =
          Message.new(
            role: :user,
            content: [Attachment.new(source: {:base64, "data"}, media_type: mt)]
          )

        context = Context.new([msg])
        {:ok, body} = AnthropicMessages.build_body(@model, context, [])

        [%{"content" => [block]}] = body["messages"]
        assert block["type"] == "image", "expected image type for #{mt}"
      end
    end
  end

  describe "build_body/3 cache control" do
    test "short cache on system prompt" do
      context = Context.new(system: "Be helpful.", messages: [Message.new("Hi")])
      {:ok, body} = AnthropicMessages.build_body(@model, context, cache: :short)

      [system_block] = body["system"]
      assert system_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "long cache on system prompt" do
      context = Context.new(system: "Be helpful.", messages: [Message.new("Hi")])
      {:ok, body} = AnthropicMessages.build_body(@model, context, cache: :long)

      [system_block] = body["system"]
      assert system_block["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "cache on last content block of last message" do
      messages = [
        Message.new(role: :user, content: [Text.new("First"), Text.new("Second")])
      ]

      context = Context.new(messages)
      {:ok, body} = AnthropicMessages.build_body(@model, context, cache: :short)

      [msg] = body["messages"]
      [first, last] = msg["content"]
      refute Map.has_key?(first, "cache_control")
      assert last["cache_control"] == %{"type" => "ephemeral"}
    end

    test "cache on last tool" do
      tools = [
        Tool.new(name: "tool_a", description: "A", input_schema: %{}),
        Tool.new(name: "tool_b", description: "B", input_schema: %{})
      ]

      context = Context.new(messages: [Message.new("Hi")], tools: tools)
      {:ok, body} = AnthropicMessages.build_body(@model, context, cache: :short)

      [first_tool, last_tool] = body["tools"]
      refute Map.has_key?(first_tool, "cache_control")
      assert last_tool["cache_control"] == %{"type" => "ephemeral"}
    end

    test "no cache omits cache_control everywhere" do
      tool = Tool.new(name: "tool_a", description: "A", input_schema: %{})

      context =
        Context.new(
          system: "Be helpful.",
          messages: [Message.new("Hi")],
          tools: [tool]
        )

      {:ok, body} = AnthropicMessages.build_body(@model, context, [])

      [system_block] = body["system"]
      refute Map.has_key?(system_block, "cache_control")

      [msg] = body["messages"]
      [content_block] = msg["content"]
      refute Map.has_key?(content_block, "cache_control")

      [encoded_tool] = body["tools"]
      refute Map.has_key?(encoded_tool, "cache_control")
    end

    test "cache only affects last message, not earlier ones" do
      messages = [
        Message.new(role: :user, content: "First message"),
        Message.new(role: :assistant, content: "Reply"),
        Message.new(role: :user, content: "Second message")
      ]

      context = Context.new(messages)
      {:ok, body} = AnthropicMessages.build_body(@model, context, cache: :short)

      [first, second, third] = body["messages"]

      [block] = first["content"]
      refute Map.has_key?(block, "cache_control")

      [block] = second["content"]
      refute Map.has_key?(block, "cache_control")

      [block] = third["content"]
      assert block["cache_control"] == %{"type" => "ephemeral"}
    end
  end

  describe "parse_event/1" do
    test "message_start" do
      event = %{
        "type" => "message_start",
        "message" => %{"model" => "claude-sonnet-4-20250514", "role" => "assistant"}
      }

      assert [{:message, %{model: "claude-sonnet-4-20250514"}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_start text" do
      event = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }

      assert [{:block_start, %{type: :text, index: 0}}] = AnthropicMessages.parse_event(event)
    end

    test "content_block_start thinking" do
      event = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }

      assert [{:block_start, %{type: :thinking, index: 0}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_start tool_use" do
      event = %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_01",
          "name" => "get_weather",
          "input" => %{}
        }
      }

      assert [{:block_start, %{type: :tool_use, index: 1, id: "toolu_01", name: "get_weather"}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_delta text_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_delta thinking_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Hmm..."}
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Hmm..."}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_delta input_json_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"city\""}
      }

      assert [{:block_delta, %{type: :tool_use, index: 1, delta: "{\"city\""}}] =
               AnthropicMessages.parse_event(event)
    end

    test "content_block_stop returns empty list" do
      event = %{"type" => "content_block_stop", "index" => 0}

      assert [] == AnthropicMessages.parse_event(event)
    end

    test "message_delta" do
      event = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 5}
      }

      assert [{:message, %{stop_reason: :stop, usage: %{"output_tokens" => 5}}}] =
               AnthropicMessages.parse_event(event)
    end

    test "ping returns empty list" do
      assert [] == AnthropicMessages.parse_event(%{"type" => "ping"})
    end

    test "message_stop returns empty list" do
      assert [] == AnthropicMessages.parse_event(%{"type" => "message_stop"})
    end

    test "unknown event returns empty list" do
      assert [] == AnthropicMessages.parse_event(%{"type" => "unknown_event"})
    end

    test "stop reason normalization" do
      make_event = fn reason ->
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => reason},
          "usage" => %{}
        }
      end

      assert [{:message, %{stop_reason: :stop}}] =
               AnthropicMessages.parse_event(make_event.("end_turn"))

      assert [{:message, %{stop_reason: :stop}}] =
               AnthropicMessages.parse_event(make_event.("stop_sequence"))

      assert [{:message, %{stop_reason: :length}}] =
               AnthropicMessages.parse_event(make_event.("max_tokens"))

      assert [{:message, %{stop_reason: :tool_use}}] =
               AnthropicMessages.parse_event(make_event.("tool_use"))
    end
  end
end
