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

  describe "handle_path/1" do
    test "returns /v1/chat/completions" do
      assert OpenAICompletions.handle_path(@model, %{}) == "/v1/chat/completions"
    end
  end

  describe "handle_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      assert body["model"] == "gpt-4.1-nano"
      refute Map.has_key?(body, "max_completion_tokens")
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      assert length(body["messages"]) == 1

      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello"
    end

    test "system prompt as first message with system role" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      body = OpenAICompletions.handle_body(@model, context, %{})

      [system_msg | rest] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
      assert length(rest) == 1
    end

    test "no system prompt omits system message" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      roles = Enum.map(body["messages"], & &1["role"])
      refute "system" in roles
    end

    test "max_tokens in opts overrides default" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{max_tokens: 1024})

      assert body["max_completion_tokens"] == 1024
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{temperature: 0.7})

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{metadata: %{"user_id" => "123"}})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      refute Map.has_key?(body, "metadata")
    end

    test "cache :long sets prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{cache: :long})

      assert body["prompt_cache_retention"] == "24h"
    end

    test "cache :short omits prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{cache: :short})

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "no cache omits prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      body = OpenAICompletions.handle_body(@model, context, %{})

      assert length(body["messages"]) == 3
      roles = Enum.map(body["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user"]
    end

    test "single text block encodes as string content" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

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
      body = OpenAICompletions.handle_body(@model, context, %{})

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "image_url"
      assert block["image_url"]["url"] == "https://example.com/image.png"
    end

    test "PDF base64 encodes as file with file_data data URL" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "pdf-data"}, media_type: "application/pdf")
          ]
        )

      context = Context.new([msg])
      body = OpenAICompletions.handle_body(@model, context, %{})

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "file"
      assert block["file"]["file_data"] == "data:application/pdf;base64,pdf-data"
    end

    test "PDF URL encodes as image_url with URL" do
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
      body = OpenAICompletions.handle_body(@model, context, %{})

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "image_url"
      assert block["image_url"]["url"] == "https://example.com/doc.pdf"
    end

    test "uncommon media type doesn't crash" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "xml-data"}, media_type: "application/xml")
          ]
        )

      context = Context.new([msg])
      body = OpenAICompletions.handle_body(@model, context, %{})

      [user_msg] = body["messages"]
      [block] = user_msg["content"]
      assert block["type"] == "file"
      assert block["file"]["file_data"] == "data:application/xml;base64,xml-data"
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
      body = OpenAICompletions.handle_body(@model, context, %{})

      [user_msg] = body["messages"]
      assert is_list(user_msg["content"])
      assert length(user_msg["content"]) == 2

      [text_part, image_part] = user_msg["content"]
      assert text_part["type"] == "text"
      assert image_part["type"] == "image_url"
    end
  end

  describe "handle_body/3 thinking" do
    @reasoning_model Model.new(
                       id: "o3-mini",
                       name: "o3-mini",
                       provider: Omni.Providers.OpenAI,
                       dialect: OpenAICompletions,
                       max_output_tokens: 32768,
                       reasoning: true
                     )

    test "thinking: true sets reasoning_effort to high" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: true})

      assert body["reasoning_effort"] == "high"
    end

    test "effort levels map correctly, :max preserves max" do
      context = Context.new("Hello")

      for {level, expected} <- [low: "low", medium: "medium", high: "high", max: "max"] do
        body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: level})

        assert body["reasoning_effort"] == expected,
               "expected #{expected} for level #{level}"
      end
    end

    test "budget is ignored" do
      context = Context.new("Hello")

      body =
        OpenAICompletions.handle_body(@reasoning_model, context, %{
          thinking: [effort: :medium, budget: 10_000]
        })

      assert body["reasoning_effort"] == "medium"
    end

    test "thinking: false is no-op" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: false})

      refute Map.has_key?(body, "reasoning_effort")
    end

    test "thinking: :none is no-op" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: :none})

      refute Map.has_key?(body, "reasoning_effort")
    end

    test "non-reasoning model ignores thinking option" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{thinking: :high})

      refute Map.has_key?(body, "reasoning_effort")
    end

    test "nil thinking is no-op" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{})

      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  describe "handle_event/1" do
    test "message from role delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert [{:message, %{model: "gpt-4.1-nano"}}] = OpenAICompletions.handle_event(event)
    end

    test "text delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}] =
               OpenAICompletions.handle_event(event)
    end

    test "empty content in start returns message not block_delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert [{:message, _}] = OpenAICompletions.handle_event(event)
    end

    test "message with stop" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event)
    end

    test "message with tool_calls" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert [{:message, %{stop_reason: :tool_use}}] = OpenAICompletions.handle_event(event)
    end

    test "message with length" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "length"}]
      }

      assert [{:message, %{stop_reason: :length}}] = OpenAICompletions.handle_event(event)
    end

    test "message with content_filter" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "content_filter"}]
      }

      assert [{:message, %{stop_reason: :refusal}}] = OpenAICompletions.handle_event(event)
    end

    test "message with function_call" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "function_call"}]
      }

      assert [{:message, %{stop_reason: :tool_use}}] = OpenAICompletions.handle_event(event)
    end

    test "unknown finish_reason maps to :stop" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "unknown_reason"}]
      }

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event)
    end

    test "message with usage from final chunk" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      assert [{:message, %{usage: usage}}] = OpenAICompletions.handle_event(event)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "tool use start with id emits message and block_start" do
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

      assert [
               {:message, %{model: "gpt-4.1-nano"}},
               {:block_start,
                %{type: :tool_use, index: 0, id: "call_abc123", name: "get_weather"}}
             ] = OpenAICompletions.handle_event(event)
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

      assert [{:block_delta, %{type: :tool_use, index: 0, delta: "{\"city\""}}] =
               OpenAICompletions.handle_event(event)
    end

    test "tool_calls with role emits message and block_start" do
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

      assert [{:message, _}, {:block_start, _}] = OpenAICompletions.handle_event(event)
    end

    test "parallel tool call start uses tool_call index not choice index" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "call_second",
                  "type" => "function",
                  "function" => %{"name" => "get_time", "arguments" => ""}
                }
              ]
            }
          }
        ],
        "model" => "gpt-4.1-nano"
      }

      assert [
               {:message, %{model: "gpt-4.1-nano"}},
               {:block_start, %{type: :tool_use, index: 1, id: "call_second", name: "get_time"}}
             ] = OpenAICompletions.handle_event(event)
    end

    test "parallel tool call delta uses tool_call index not choice index" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 1, "function" => %{"arguments" => "{\"city\""}}
              ]
            }
          }
        ]
      }

      assert [{:block_delta, %{type: :tool_use, index: 1, delta: "{\"city\""}}] =
               OpenAICompletions.handle_event(event)
    end

    test "empty delta returns empty list" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => nil}]
      }

      assert [] == OpenAICompletions.handle_event(event)
    end

    test "reasoning_content delta emits thinking block_delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => "Let me think..."}}]
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Let me think..."}}] =
               OpenAICompletions.handle_event(event)
    end

    test "empty reasoning_content returns empty list" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => ""}}]
      }

      assert [] == OpenAICompletions.handle_event(event)
    end

    test "unknown event returns empty list" do
      assert [] == OpenAICompletions.handle_event(%{"type" => "something_else"})
    end
  end

  describe "handle_body/3 output" do
    test "output schema sets response_format with json_schema" do
      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      body = OpenAICompletions.handle_body(@model, context, %{output: schema})

      json_schema = body["response_format"]["json_schema"]
      assert body["response_format"]["type"] == "json_schema"
      assert json_schema["name"] == "output"
      assert json_schema["strict"] == true
      assert json_schema["schema"] == schema
    end

    test "no output omits response_format" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      refute Map.has_key?(body, "response_format")
    end
  end
end
