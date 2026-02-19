defmodule Omni.Dialects.OpenAICompletionsTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.OpenAICompletions
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Model, Tool}

  @model Model.new(
           id: "gpt-4.1-nano",
           name: "GPT-4.1 nano",
           provider: Omni.Providers.OpenAI,
           dialect: OpenAICompletions,
           max_output_tokens: 32768
         )

  describe "option_schema/0" do
    test "returns empty map" do
      assert OpenAICompletions.option_schema() == %{}
    end
  end

  describe "build_path/1" do
    test "returns /v1/chat/completions" do
      assert OpenAICompletions.build_path(@model) == "/v1/chat/completions"
    end
  end

  describe "build_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert body["model"] == "gpt-4.1-nano"
      assert body["max_completion_tokens"] == 4096
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      assert length(body["messages"]) == 1

      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello"
    end

    test "system prompt as first message with system role" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [system_msg | rest] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
      assert length(rest) == 1
    end

    test "no system prompt omits system message" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      roles = Enum.map(body["messages"], & &1["role"])
      refute "system" in roles
    end

    test "max_tokens in opts overrides default" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, max_tokens: 1024)

      assert body["max_completion_tokens"] == 1024
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, temperature: 0.7)

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, metadata: %{"user_id" => "123"})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      refute Map.has_key?(body, "metadata")
    end

    test "cache :long sets prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, cache: :long)

      assert body["prompt_cache_retention"] == "24h"
    end

    test "cache :short omits prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, cache: :short)

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "no cache omits prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "tools with function wrapper and parameters key" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("What's the weather?")], tools: [tool])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "function"
      assert encoded_tool["function"]["name"] == "get_weather"
      assert encoded_tool["function"]["description"] == "Gets the weather"

      assert encoded_tool["function"]["parameters"] == %{
               type: "object",
               properties: %{city: %{type: "string"}}
             }
    end

    test "empty tools omits key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert length(body["messages"]) == 3
      roles = Enum.map(body["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user"]
    end

    test "single text block encodes as string content" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [user_msg] = body["messages"]
      assert user_msg["content"] == "Hello"
    end

    test "multiple content blocks encode as parts array" do
      msg =
        Message.new(
          role: :user,
          content: [Text.new("Hello"), Text.new("World")]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [user_msg] = body["messages"]
      assert is_list(user_msg["content"])
      assert length(user_msg["content"]) == 2

      assert [
               %{"type" => "text", "text" => "Hello"},
               %{"type" => "text", "text" => "World"}
             ] = user_msg["content"]
    end

    test "assistant text message" do
      msg = Message.new(role: :assistant, content: "Hi there!")
      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [assistant_msg] = body["messages"]
      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] == "Hi there!"
    end

    test "assistant with ToolUse encodes tool_calls with JSON arguments" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            ToolUse.new(id: "call_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [assistant_msg] = body["messages"]
      assert [tool_call] = assistant_msg["tool_calls"]
      assert tool_call["id"] == "call_01"
      assert tool_call["type"] == "function"
      assert tool_call["function"]["name"] == "get_weather"
      assert tool_call["function"]["arguments"] == ~s({"city":"London"})
    end

    test "assistant with text and ToolUse" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            Text.new("Let me check the weather."),
            ToolUse.new(id: "call_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [assistant_msg] = body["messages"]
      assert assistant_msg["content"] == "Let me check the weather."
      assert [tool_call] = assistant_msg["tool_calls"]
      assert tool_call["function"]["name"] == "get_weather"
    end

    test "assistant with Thinking block skips it" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            Thinking.new(text: "Let me think...", signature: "sig123"),
            Text.new("Here's the answer.")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [assistant_msg] = body["messages"]
      assert assistant_msg["content"] == "Here's the answer."
      refute Map.has_key?(assistant_msg, "tool_calls")
    end

    test "user with ToolResult encodes as tool role messages" do
      msg =
        Message.new(
          role: :user,
          content: [
            ToolResult.new(
              tool_use_id: "call_01",
              name: "get_weather",
              content: "Sunny, 22°C",
              is_error: false
            )
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert [tool_msg] = body["messages"]
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "call_01"
      assert tool_msg["content"] == "Sunny, 22°C"
    end

    test "mixed ToolResult and Text splits correctly" do
      msg =
        Message.new(
          role: :user,
          content: [
            ToolResult.new(
              tool_use_id: "call_01",
              name: "get_weather",
              content: "Sunny",
              is_error: false
            ),
            Text.new("Thanks!")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert length(body["messages"]) == 2

      [tool_msg, user_msg] = body["messages"]
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "call_01"

      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Thanks!"
    end

    test "multiple ToolResults encode as multiple tool messages with no user message" do
      msg =
        Message.new(
          role: :user,
          content: [
            ToolResult.new(
              tool_use_id: "call_01",
              name: "get_weather",
              content: "Sunny",
              is_error: false
            ),
            ToolResult.new(
              tool_use_id: "call_02",
              name: "get_time",
              content: "3pm",
              is_error: false
            )
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      assert length(body["messages"]) == 2

      roles = Enum.map(body["messages"], & &1["role"])
      assert roles == ["tool", "tool"]
    end

    test "image base64 encodes as data URI in image_url" do
      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, "abc123"}, media_type: "image/png")]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "image_url"
      assert block["image_url"]["url"] == "data:image/png;base64,abc123"
    end

    test "image URL encodes directly in image_url" do
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
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "image_url"
      assert block["image_url"]["url"] == "https://example.com/image.png"
    end

    test "text and image encode as content array" do
      msg =
        Message.new(
          role: :user,
          content: [
            Text.new("What's in this image?"),
            Attachment.new(source: {:base64, "data"}, media_type: "image/jpeg")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = OpenAICompletions.build_body(@model, context, [])

      [user_msg] = body["messages"]
      assert is_list(user_msg["content"])
      assert length(user_msg["content"]) == 2

      [text_part, image_part] = user_msg["content"]
      assert text_part["type"] == "text"
      assert image_part["type"] == "image_url"
    end
  end

  describe "parse_event/1" do
    test "start from role delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert {:start, %{model: "gpt-4.1-nano"}} = OpenAICompletions.parse_event(event)
    end

    test "text delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]
      }

      assert {:text_delta, %{index: 0, delta: "Hello"}} = OpenAICompletions.parse_event(event)
    end

    test "empty content in start returns start not text_delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert {:start, _} = OpenAICompletions.parse_event(event)
    end

    test "done with stop" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      assert {:done, %{stop_reason: :stop}} = OpenAICompletions.parse_event(event)
    end

    test "done with tool_calls" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert {:done, %{stop_reason: :tool_use}} = OpenAICompletions.parse_event(event)
    end

    test "done with length" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "length"}]
      }

      assert {:done, %{stop_reason: :length}} = OpenAICompletions.parse_event(event)
    end

    test "done with content_filter" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "content_filter"}]
      }

      assert {:done, %{stop_reason: :content_filter}} = OpenAICompletions.parse_event(event)
    end

    test "usage from final chunk with normalized keys" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      assert {:usage, %{usage: usage}} = OpenAICompletions.parse_event(event)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "tool use start with id" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ""}
                }
              ]
            }
          }
        ],
        "model" => "gpt-4.1-nano"
      }

      assert {:tool_use_start, %{index: 0, id: "call_abc123", name: "get_weather"}} =
               OpenAICompletions.parse_event(event)
    end

    test "tool use delta without id" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "{\"city\""}}
              ]
            }
          }
        ]
      }

      assert {:tool_use_delta, %{index: 0, delta: "{\"city\""}} =
               OpenAICompletions.parse_event(event)
    end

    test "tool use start takes priority over start when both role and tool_calls present" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ""}
                }
              ]
            }
          }
        ],
        "model" => "gpt-4.1-nano"
      }

      assert {:tool_use_start, _} = OpenAICompletions.parse_event(event)
    end

    test "empty delta returns nil" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => nil}]
      }

      assert nil == OpenAICompletions.parse_event(event)
    end

    test "unknown event returns nil" do
      assert nil == OpenAICompletions.parse_event(%{"type" => "something_else"})
    end
  end
end
