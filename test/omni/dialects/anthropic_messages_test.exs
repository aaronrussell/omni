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
    test "returns max_tokens with default" do
      assert AnthropicMessages.option_schema() == %{max_tokens: {:integer, {:default, 4096}}}
    end
  end

  describe "handle_path/1" do
    test "returns /v1/messages" do
      assert AnthropicMessages.handle_path(@model, %{}) == "/v1/messages"
    end
  end

  describe "handle_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{max_tokens: 4096})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

      assert [%{"type" => "text", "text" => "You are helpful."}] = body["system"]
    end

    test "no system prompt omits key" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{})

      refute Map.has_key?(body, "system")
    end

    test "max_tokens in opts overrides default" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{max_tokens: 1024})

      assert body["max_tokens"] == 1024
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{temperature: 0.7})

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{})

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{metadata: %{"user_id" => "123"}})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      body = AnthropicMessages.handle_body(@model, context, %{})

      assert length(body["messages"]) == 3
      roles = Enum.map(body["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user"]
    end

    test "encodes Text content block" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      assert [%{"content" => [%{"type" => "text", "text" => "Hello"}]}] = body["messages"]
    end

    test "encodes Thinking content block" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: "Let me think...", signature: "sig123")]
        )

      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "thinking"
      assert block["thinking"] == "Let me think..."
      assert block["signature"] == "sig123"
    end

    test "encodes redacted thinking content block" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: nil, redacted_data: "encrypted_blob")]
        )

      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block == %{"type" => "redacted_thinking", "data" => "encrypted_blob"}
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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "url"
      assert block["source"]["url"] == "https://example.com/doc.pdf"
    end

    test "encodes text/plain attachment with base64 as document with decoded text source" do
      plain_text = Base.encode64("Hello, world!")

      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, plain_text}, media_type: "text/plain")]
        )

      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "text"
      assert block["source"]["media_type"] == "text/plain"
      assert block["source"]["data"] == "Hello, world!"
    end

    test "encodes text/plain attachment with URL as document with URL source" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(
              source: {:url, "https://example.com/file.txt"},
              media_type: "text/plain"
            )
          ]
        )

      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "url"
      assert block["source"]["url"] == "https://example.com/file.txt"
    end

    test "encodes application/xml attachment with base64 as document (catch-all)" do
      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, "xml-data"}, media_type: "application/xml")]
        )

      context = Context.new([msg])
      body = AnthropicMessages.handle_body(@model, context, %{})

      [%{"content" => [block]}] = body["messages"]
      assert block["type"] == "document"
      assert block["source"]["type"] == "base64"
      assert block["source"]["media_type"] == "application/xml"
      assert block["source"]["data"] == "xml-data"
    end

    test "all image media types encode as image" do
      for mt <- ~w(image/jpeg image/png image/gif image/webp) do
        msg =
          Message.new(
            role: :user,
            content: [Attachment.new(source: {:base64, "data"}, media_type: mt)]
          )

        context = Context.new([msg])
        body = AnthropicMessages.handle_body(@model, context, %{})

        [%{"content" => [block]}] = body["messages"]
        assert block["type"] == "image", "expected image type for #{mt}"
      end
    end
  end

  describe "handle_body/3 thinking" do
    @reasoning_model Model.new(
                       id: "claude-3.5-sonnet-20241022",
                       name: "Claude 3.5 Sonnet",
                       provider: Omni.Providers.Anthropic,
                       dialect: AnthropicMessages,
                       max_output_tokens: 8192,
                       reasoning: true
                     )

    @adaptive_model Model.new(
                      id: "claude-sonnet-4.6-20260214",
                      name: "Claude Sonnet 4.6",
                      provider: Omni.Providers.Anthropic,
                      dialect: AnthropicMessages,
                      max_output_tokens: 8192,
                      reasoning: true
                    )

    test "thinking: :high with non-4.6 model uses manual format" do
      context = Context.new("Hello")

      body =
        AnthropicMessages.handle_body(@reasoning_model, context, %{
          thinking: :high,
          max_tokens: 4096
        })

      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 16384}
      assert body["max_tokens"] == 4096 + 16384
    end

    test "thinking: :high with 4.6 model uses adaptive format" do
      context = Context.new("Hello")

      body =
        AnthropicMessages.handle_body(@adaptive_model, context, %{
          thinking: :high,
          max_tokens: 4096
        })

      assert body["thinking"] == %{"type" => "adaptive"}
      assert body["output_config"] == %{"effort" => "high"}
      assert body["max_tokens"] == 4096
    end

    test "effort levels map to correct budgets in manual mode" do
      context = Context.new("Hello")

      for {level, expected_budget} <- [low: 1024, medium: 4096, high: 16384, max: 32768] do
        body =
          AnthropicMessages.handle_body(@reasoning_model, context, %{
            thinking: level,
            max_tokens: 4096
          })

        assert body["thinking"]["budget_tokens"] == expected_budget,
               "expected budget #{expected_budget} for level #{level}"

        assert body["max_tokens"] == 4096 + expected_budget
      end
    end

    test "effort levels map to correct effort strings in adaptive mode" do
      context = Context.new("Hello")

      for level <- [:low, :medium, :high, :max] do
        body =
          AnthropicMessages.handle_body(@adaptive_model, context, %{thinking: level})

        assert body["thinking"] == %{"type" => "adaptive"}
        assert body["output_config"]["effort"] == to_string(level)
      end
    end

    test "explicit budget in map form (manual path)" do
      context = Context.new("Hello")

      body =
        AnthropicMessages.handle_body(@reasoning_model, context, %{
          thinking: %{effort: :high, budget: 10_000},
          max_tokens: 4096
        })

      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 10_000}
      assert body["max_tokens"] == 4096 + 10_000
    end

    test "thinking: false sets disabled" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@reasoning_model, context, %{thinking: false})

      assert body["thinking"] == %{"type" => "disabled"}
    end

    test "temperature is dropped when thinking is active" do
      context = Context.new("Hello")

      body =
        AnthropicMessages.handle_body(@reasoning_model, context, %{
          thinking: :high,
          temperature: 0.7,
          max_tokens: 4096
        })

      refute Map.has_key?(body, "temperature")
    end

    test "max_tokens not adjusted for adaptive mode" do
      context = Context.new("Hello")

      body =
        AnthropicMessages.handle_body(@adaptive_model, context, %{
          thinking: :high,
          max_tokens: 2048
        })

      assert body["max_tokens"] == 2048
    end

    test "non-reasoning model ignores thinking option" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{thinking: :high})

      refute Map.has_key?(body, "thinking")
    end

    test "non-reasoning model with false is no-op" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{thinking: false})

      refute Map.has_key?(body, "thinking")
    end

    test "nil thinking is no-op" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@reasoning_model, context, %{})

      refute Map.has_key?(body, "thinking")
    end
  end

  describe "handle_body/3 cache control" do
    test "short cache on system prompt" do
      context = Context.new(system: "Be helpful.", messages: [Message.new("Hi")])
      body = AnthropicMessages.handle_body(@model, context, %{cache: :short})

      [system_block] = body["system"]
      assert system_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "long cache on system prompt" do
      context = Context.new(system: "Be helpful.", messages: [Message.new("Hi")])
      body = AnthropicMessages.handle_body(@model, context, %{cache: :long})

      [system_block] = body["system"]
      assert system_block["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "cache on last content block of last message" do
      messages = [
        Message.new(role: :user, content: [Text.new("First"), Text.new("Second")])
      ]

      context = Context.new(messages)
      body = AnthropicMessages.handle_body(@model, context, %{cache: :short})

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
      body = AnthropicMessages.handle_body(@model, context, %{cache: :short})

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

      body = AnthropicMessages.handle_body(@model, context, %{})

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
      body = AnthropicMessages.handle_body(@model, context, %{cache: :short})

      [first, second, third] = body["messages"]

      [block] = first["content"]
      refute Map.has_key?(block, "cache_control")

      [block] = second["content"]
      refute Map.has_key?(block, "cache_control")

      [block] = third["content"]
      assert block["cache_control"] == %{"type" => "ephemeral"}
    end
  end

  describe "handle_event/1" do
    test "message_start" do
      event = %{
        "type" => "message_start",
        "message" => %{"model" => "claude-sonnet-4-20250514", "role" => "assistant"}
      }

      assert [{:message, %{model: "claude-sonnet-4-20250514"}}] =
               AnthropicMessages.handle_event(event)
    end

    test "content_block_start text" do
      event = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }

      assert [{:block_start, %{type: :text, index: 0}}] = AnthropicMessages.handle_event(event)
    end

    test "content_block_start thinking" do
      event = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }

      assert [{:block_start, %{type: :thinking, index: 0}}] =
               AnthropicMessages.handle_event(event)
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
               AnthropicMessages.handle_event(event)
    end

    test "content_block_delta text_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}] =
               AnthropicMessages.handle_event(event)
    end

    test "content_block_delta thinking_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Hmm..."}
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Hmm..."}}] =
               AnthropicMessages.handle_event(event)
    end

    test "content_block_delta input_json_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"city\""}
      }

      assert [{:block_delta, %{type: :tool_use, index: 1, delta: "{\"city\""}}] =
               AnthropicMessages.handle_event(event)
    end

    test "content_block_stop returns empty list" do
      event = %{"type" => "content_block_stop", "index" => 0}

      assert [] == AnthropicMessages.handle_event(event)
    end

    test "message_delta" do
      event = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 5}
      }

      assert [{:message, %{stop_reason: :stop, usage: %{"output_tokens" => 5}}}] =
               AnthropicMessages.handle_event(event)
    end

    test "ping returns empty list" do
      assert [] == AnthropicMessages.handle_event(%{"type" => "ping"})
    end

    test "message_stop returns empty list" do
      assert [] == AnthropicMessages.handle_event(%{"type" => "message_stop"})
    end

    test "unknown event returns empty list" do
      assert [] == AnthropicMessages.handle_event(%{"type" => "unknown_event"})
    end

    test "content_block_start redacted_thinking" do
      event = %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{"type" => "redacted_thinking", "data" => "encrypted_blob_data"}
      }

      assert [{:block_start, %{type: :thinking, index: 2, redacted_data: "encrypted_blob_data"}}] =
               AnthropicMessages.handle_event(event)
    end

    test "content_block_delta signature_delta" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig_abc123"}
      }

      assert [{:block_delta, %{type: :thinking, index: 0, signature: "sig_abc123"}}] =
               AnthropicMessages.handle_event(event)
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
               AnthropicMessages.handle_event(make_event.("end_turn"))

      assert [{:message, %{stop_reason: :stop}}] =
               AnthropicMessages.handle_event(make_event.("stop_sequence"))

      assert [{:message, %{stop_reason: :length}}] =
               AnthropicMessages.handle_event(make_event.("max_tokens"))

      assert [{:message, %{stop_reason: :tool_use}}] =
               AnthropicMessages.handle_event(make_event.("tool_use"))

      assert [{:message, %{stop_reason: :length}}] =
               AnthropicMessages.handle_event(make_event.("pause_turn"))

      assert [{:message, %{stop_reason: :refusal}}] =
               AnthropicMessages.handle_event(make_event.("refusal"))

      assert [{:message, %{stop_reason: :length}}] =
               AnthropicMessages.handle_event(make_event.("model_context_window_exceeded"))

      assert [{:message, %{stop_reason: :stop}}] =
               AnthropicMessages.handle_event(make_event.("unknown_reason"))
    end
  end

  describe "handle_body/3 output" do
    test "output schema sets output_config with json_schema format" do
      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      body = AnthropicMessages.handle_body(@model, context, %{output: schema})

      assert body["output_config"]["format"]["type"] == "json_schema"

      wire_schema = body["output_config"]["format"]["schema"]
      assert wire_schema[:additionalProperties] == false
      assert wire_schema[:type] == "object"
      assert wire_schema[:properties] == schema[:properties]
    end

    test "non-object output schema does not get additionalProperties" do
      context = Context.new("Hello")
      schema = %{type: "array", items: %{type: "string"}}
      body = AnthropicMessages.handle_body(@model, context, %{output: schema})

      wire_schema = body["output_config"]["format"]["schema"]
      refute Map.has_key?(wire_schema, :additionalProperties)
    end

    test "output schema merges with thinking output_config" do
      adaptive_model =
        Model.new(
          id: "claude-sonnet-4.6-20260214",
          name: "Claude Sonnet 4.6",
          provider: Omni.Providers.Anthropic,
          dialect: AnthropicMessages,
          max_output_tokens: 8192,
          reasoning: true
        )

      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}

      body =
        AnthropicMessages.handle_body(adaptive_model, context, %{thinking: :high, output: schema})

      # Both effort and format should be present
      assert body["output_config"]["effort"] == "high"
      assert body["output_config"]["format"]["type"] == "json_schema"
    end

    test "no output omits output_config format" do
      context = Context.new("Hello")
      body = AnthropicMessages.handle_body(@model, context, %{})

      refute Map.has_key?(body, "output_config")
    end
  end
end
