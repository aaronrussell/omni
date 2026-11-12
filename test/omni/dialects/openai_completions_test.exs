defmodule Omni.Dialects.OpenAICompletionsTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.OpenAICompletions
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Tool}
  alias Omni.Test.Fixtures

  @model Fixtures.model(
           id: "gpt-4.1-nano",
           name: "GPT-4.1 nano",
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
      assert OpenAICompletions.handle_path(@model, %{}) == "/chat/completions"
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
    @reasoning_model Fixtures.model(
                       id: "o3-mini",
                       name: "o3-mini",
                       dialect: OpenAICompletions,
                       max_output_tokens: 32768,
                       thinking: true
                     )

    test "thinking: :high sets reasoning_effort to high" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: :high})

      assert body["reasoning_effort"] == "high"
    end

    test "effort levels map correctly, :max maps to xhigh" do
      context = Context.new("Hello")

      for {level, expected} <- [
            low: "low",
            medium: "medium",
            high: "high",
            xhigh: "xhigh",
            max: "xhigh"
          ] do
        body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: level})

        assert body["reasoning_effort"] == expected,
               "expected #{expected} for level #{level}"
      end
    end

    test "budget is ignored" do
      context = Context.new("Hello")

      body =
        OpenAICompletions.handle_body(@reasoning_model, context, %{
          thinking: %{effort: :medium, budget: 10_000}
        })

      assert body["reasoning_effort"] == "medium"
    end

    test "thinking: false sets reasoning_effort to none" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@reasoning_model, context, %{thinking: false})

      assert body["reasoning_effort"] == "none"
    end

    test "levels clamp to the model's effort values" do
      model = %{@reasoning_model | thinking: %{efforts: ["low", "medium", "high"]}}
      body = OpenAICompletions.handle_body(model, Context.new("Hello"), %{thinking: :max})

      assert body["reasoning_effort"] == "high"
    end

    test "thinking: false sends nothing to a model that can't switch off" do
      model = %{@reasoning_model | thinking: %{efforts: ["low", "medium", "high"]}}
      body = OpenAICompletions.handle_body(model, Context.new("Hello"), %{thinking: false})

      refute Map.has_key?(body, "reasoning_effort")
    end

    test "thinking: true sends medium" do
      body =
        OpenAICompletions.handle_body(@reasoning_model, Context.new("Hello"), %{thinking: true})

      assert body["reasoning_effort"] == "medium"
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

  describe "handle_event/2" do
    test "message from role delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert [{:message, %{model: "gpt-4.1-nano"}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "text delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "empty content in start returns message not block_delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}}],
        "model" => "gpt-4.1-nano"
      }

      assert [{:message, _}] = OpenAICompletions.handle_event(event, @model)
    end

    test "message with stop" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "message with tool_calls" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert [{:message, %{stop_reason: :tool_use}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "message with length" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "length"}]
      }

      assert [{:message, %{stop_reason: :length}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "message with content_filter" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "content_filter"}]
      }

      assert [{:message, %{stop_reason: :refusal}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "message with function_call" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "function_call"}]
      }

      assert [{:message, %{stop_reason: :tool_use}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "unknown finish_reason maps to :stop" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "unknown_reason"}]
      }

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "Z.ai sensitive finish_reason maps to :refusal" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "sensitive"}]
      }

      assert [{:message, %{stop_reason: :refusal}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "Z.ai model_context_window_exceeded finish_reason maps to :length" do
      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "model_context_window_exceeded"}
        ]
      }

      assert [{:message, %{stop_reason: :length}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "Z.ai network_error finish_reason maps to :error" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "network_error"}]
      }

      assert [{:message, %{stop_reason: :error}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "Mistral model_length and error finish_reasons map to :length and :error" do
      for {reason, expected} <- [{"model_length", :length}, {"error", :error}] do
        event = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}

        assert [{:message, %{stop_reason: ^expected}}] =
                 OpenAICompletions.handle_event(event, @model)
      end
    end

    test "Together eos finish_reason maps to :stop" do
      event = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "eos"}]}

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event, @model)
    end

    test "content as a list of thinking and text chunks" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "content" => [
                %{
                  "type" => "thinking",
                  "thinking" => [%{"type" => "text", "text" => "2+2=4."}],
                  "signature" => "sig"
                },
                %{"type" => "text", "text" => "4"}
              ]
            }
          }
        ]
      }

      assert [
               {:block_delta, %{type: :thinking, index: 0, delta: "2+2=4."}},
               {:block_delta, %{type: :thinking, index: 0, signature: "sig"}},
               {:block_delta, %{type: :text, index: 0, delta: "4"}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "content chunks skip empty text and unknown chunk types" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "content" => [
                %{"type" => "thinking", "thinking" => [%{"type" => "text", "text" => ""}]},
                %{"type" => "reference", "reference_ids" => [1]},
                %{"type" => "text", "text" => ""}
              ]
            }
          }
        ]
      }

      assert [] = OpenAICompletions.handle_event(event, @model)
    end

    test "tool calls without index take their position in the list" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "content" => nil,
              "tool_calls" => [
                %{"id" => "aaaaaaaaa", "function" => %{"name" => "a", "arguments" => "{}"}},
                %{"id" => "bbbbbbbbb", "function" => %{"name" => "b", "arguments" => "{}"}}
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      assert [
               {:block_start, %{type: :tool_use, index: 0, id: "aaaaaaaaa", name: "a"}},
               {:block_delta, %{type: :tool_use, index: 0, delta: "{}"}},
               {:block_start, %{type: :tool_use, index: 1, id: "bbbbbbbbb", name: "b"}},
               {:block_delta, %{type: :tool_use, index: 1, delta: "{}"}},
               {:message, %{stop_reason: :tool_use}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "a tool call continuation with an empty name is not a new call" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "content" => "",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "type" => "function",
                  "function" => %{"name" => "", "arguments" => "{\"city\": \"London\"}"}
                }
              ]
            }
          }
        ]
      }

      assert [{:block_delta, %{type: :tool_use, index: 0, delta: "{\"city\": \"London\"}"}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "tool call arguments as a JSON object are encoded to a string" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"id" => "aaaaaaaaa", "function" => %{"name" => "a", "arguments" => %{"x" => 1}}}
              ]
            }
          }
        ]
      }

      assert [
               {:block_start, %{type: :tool_use, index: 0, id: "aaaaaaaaa"}},
               {:block_delta, %{type: :tool_use, index: 0, delta: ~s({"x":1})}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "message with usage from final chunk" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      assert [{:message, %{usage: usage}}] = OpenAICompletions.handle_event(event, @model)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "usage takes cached tokens from prompt_tokens_details out of input" do
      event = %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 46,
          "completion_tokens" => 17,
          "total_tokens" => 63,
          "prompt_tokens_details" => %{"cached_tokens" => 20}
        }
      }

      assert [{:message, %{usage: usage}}] = OpenAICompletions.handle_event(event, @model)
      assert usage["input_tokens"] == 26
      assert usage["output_tokens"] == 17
      assert usage["cache_read_tokens"] == 20
    end

    test "usage takes cached tokens reported flat on usage (Together)" do
      event = %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 46,
          "completion_tokens" => 17,
          "total_tokens" => 63,
          "cached_tokens" => 20
        }
      }

      assert [{:message, %{usage: usage}}] = OpenAICompletions.handle_event(event, @model)
      assert usage["input_tokens"] == 26
      assert usage["cache_read_tokens"] == 20
    end

    test "usage without prompt_tokens_details omits cache_read_tokens" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      assert [{:message, %{usage: usage}}] = OpenAICompletions.handle_event(event, @model)
      refute Map.has_key?(usage, "cache_read_tokens")
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
             ] = OpenAICompletions.handle_event(event, @model)
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
               OpenAICompletions.handle_event(event, @model)
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

      assert [{:message, _}, {:block_start, _}] = OpenAICompletions.handle_event(event, @model)
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
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "several tool calls packed in one delta each start a block" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_first",
                  "type" => "function",
                  "function" => %{"name" => "get_time", "arguments" => "{\"city\":\"London\"}"}
                },
                %{
                  "index" => 1,
                  "id" => "call_second",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => "{\"city\":\"Paris\"}"}
                }
              ]
            }
          }
        ],
        "model" => "gpt-4.1-nano"
      }

      assert [
               {:message, %{model: "gpt-4.1-nano"}},
               {:block_start, %{index: 0, id: "call_first", name: "get_time"}},
               {:block_delta, %{index: 0, delta: "{\"city\":\"London\"}"}},
               {:block_start, %{index: 1, id: "call_second", name: "get_weather"}},
               {:block_delta, %{index: 1, delta: "{\"city\":\"Paris\"}"}}
             ] = OpenAICompletions.handle_event(event, @model)
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
               OpenAICompletions.handle_event(event, @model)
    end

    test "empty delta returns empty list" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => nil}]
      }

      assert [] == OpenAICompletions.handle_event(event, @model)
    end

    test "reasoning_content delta emits thinking block_delta" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => "Let me think..."}}]
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Let me think..."}}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "empty reasoning_content returns empty list" do
      event = %{
        "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => ""}}]
      }

      assert [] == OpenAICompletions.handle_event(event, @model)
    end

    test "unknown event returns empty list" do
      assert [] == OpenAICompletions.handle_event(%{"type" => "something_else"}, @model)
    end

    test "error event returns error delta" do
      event = %{
        "error" => %{
          "message" => "The server had an error while processing your request.",
          "type" => "server_error",
          "param" => nil,
          "code" => nil
        }
      }

      assert [{:error, "The server had an error while processing your request."}] =
               OpenAICompletions.handle_event(event, @model)
    end

    test "packed chunk: tool_call args + finish_reason extracts both" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "2+2\"}"}}
              ],
              "content" => ""
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 12, "total_tokens" => 62}
      }

      result = OpenAICompletions.handle_event(event, @model)

      assert [
               {:block_delta, %{type: :tool_use, index: 0, delta: "2+2\"}"}},
               {:message, %{stop_reason: :tool_use, usage: usage}}
             ] = result

      assert usage["input_tokens"] == 50
      assert usage["output_tokens"] == 12
    end

    test "packed chunk: reasoning_content + content extracts both" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"reasoning_content" => " Done.", "content" => "The answer"}
          }
        ]
      }

      assert [
               {:block_delta, %{type: :thinking, index: 0, delta: " Done."}},
               {:block_delta, %{type: :text, index: 0, delta: "The answer"}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "packed chunk: content + finish_reason extracts both" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"content" => "final word"},
            "finish_reason" => "stop"
          }
        ]
      }

      assert [
               {:block_delta, %{type: :text, index: 0, delta: "final word"}},
               {:message, %{stop_reason: :stop}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "packed chunk: tool_call start + finish_reason extracts both" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_packed",
                  "function" => %{"name" => "calc", "arguments" => "{\"x\":1}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "model" => "test-model"
      }

      assert [
               {:message, %{model: "test-model"}},
               {:block_start, %{type: :tool_use, index: 0, id: "call_packed", name: "calc"}},
               {:block_delta, %{type: :tool_use, index: 0, delta: "{\"x\":1}"}},
               {:message, %{stop_reason: :tool_use}}
             ] = OpenAICompletions.handle_event(event, @model)
    end

    test "packed chunk: reasoning + content + finish_reason extracts all" do
      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"reasoning_content" => "think", "content" => "speak"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      assert [
               {:block_delta, %{type: :thinking, index: 0, delta: "think"}},
               {:block_delta, %{type: :text, index: 0, delta: "speak"}},
               {:message, %{stop_reason: :stop, usage: usage}}
             ] = OpenAICompletions.handle_event(event, @model)

      assert usage["input_tokens"] == 10
    end

    test "finish_reason without delta key still emits stop" do
      event = %{
        "choices" => [%{"index" => 0, "finish_reason" => "stop"}]
      }

      assert [{:message, %{stop_reason: :stop}}] = OpenAICompletions.handle_event(event, @model)
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
      assert json_schema["schema"] == Map.put(schema, :additionalProperties, false)
    end

    test "no output omits response_format" do
      context = Context.new("Hello")
      body = OpenAICompletions.handle_body(@model, context, %{})

      refute Map.has_key?(body, "response_format")
    end
  end

  describe "compat flags" do
    defp flagged(flags, attrs \\ []) do
      Fixtures.model(
        Keyword.merge(
          [
            id: "flagged",
            dialect: OpenAICompletions,
            provider: %{compat: Map.new(flags)}
          ],
          attrs
        )
      )
    end

    defp body(model, opts, context \\ Context.new("Hello")) do
      OpenAICompletions.handle_body(model, context, opts)
    end

    test "compat_schema/0 declares every flag" do
      assert OpenAICompletions.compat_schema() |> Map.keys() |> Enum.sort() == [
               :attachment_format,
               :extra_body,
               :max_tokens_field,
               :omit,
               :output_format,
               :thinking_budget_field,
               :thinking_effort_field,
               :thinking_replay_format,
               :thinking_toggle_format
             ]
    end

    test "max_tokens_field renames max_completion_tokens" do
      result = body(flagged(max_tokens_field: "max_tokens"), %{max_tokens: 100})

      assert result["max_tokens"] == 100
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "thinking_effort_field nests the effort, including off" do
      model = flagged([thinking_effort_field: "reasoning.effort"], thinking: true)

      assert body(model, %{thinking: :high})["reasoning"] == %{"effort" => "high"}
      assert body(model, %{thinking: false})["reasoning"] == %{"effort" => "none"}
      refute Map.has_key?(body(model, %{thinking: :high}), "reasoning_effort")
    end

    test "thinking_toggle_format :thinking_type switches toggle models" do
      model = flagged([thinking_toggle_format: :thinking_type], thinking: %{toggle: true})

      assert body(model, %{thinking: :low})["thinking"] == %{"type" => "enabled"}
      assert body(model, %{thinking: true})["thinking"] == %{"type" => "enabled"}
      assert body(model, %{thinking: false})["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body(model, %{thinking: :low}), "reasoning_effort")
    end

    test "a toggle format applies to models with no thinking data" do
      model = flagged([thinking_toggle_format: :thinking_type], thinking: true)

      assert body(model, %{thinking: :high})["thinking"] == %{"type" => "enabled"}
      assert body(model, %{thinking: false})["thinking"] == %{"type" => "disabled"}
    end

    test "effort models take the effort even when a toggle format is set" do
      model =
        flagged([thinking_toggle_format: :thinking_type],
          thinking: %{efforts: ["low", "high", "max"]}
        )

      result = body(model, %{thinking: :medium})
      assert result["reasoning_effort"] == "high"
      refute Map.has_key?(result, "thinking")
    end

    test "effort models with a toggle switch off with the toggle" do
      model =
        flagged([thinking_toggle_format: :thinking_type],
          thinking: %{toggle: true, efforts: ["high", "max"]}
        )

      assert body(model, %{thinking: false})["thinking"] == %{"type" => "disabled"}
      assert body(model, %{thinking: :high})["reasoning_effort"] == "high"
    end

    test "enable_thinking with a budget field sends a budget" do
      model =
        flagged(
          [thinking_toggle_format: :enable_thinking, thinking_budget_field: "thinking_budget"],
          thinking: %{toggle: true, budget: {nil, nil}}
        )

      result = body(model, %{thinking: :high})
      assert result["enable_thinking"] == true
      assert result["thinking_budget"] == 16_384

      assert body(model, %{thinking: false}) |> Map.take(["enable_thinking", "thinking_budget"]) ==
               %{"enable_thinking" => false}

      assert body(model, %{thinking: true}) |> Map.take(["enable_thinking", "thinking_budget"]) ==
               %{"enable_thinking" => true, "thinking_budget" => 4096}
    end

    test "models with effort values get the effort and no budget" do
      model =
        flagged(
          [thinking_toggle_format: :enable_thinking, thinking_budget_field: "thinking_budget"],
          thinking: %{toggle: true, efforts: ["low", "medium", "xhigh"], budget: {0, 262_144}}
        )

      result = body(model, %{thinking: :high})
      assert result["reasoning_effort"] == "xhigh"
      refute Map.has_key?(result, "thinking_budget")
      refute Map.has_key?(result, "enable_thinking")

      assert body(model, %{thinking: false})["enable_thinking"] == false
    end

    test "no budget is sent to models without a budget range" do
      model =
        flagged(
          [thinking_toggle_format: :enable_thinking, thinking_budget_field: "thinking_budget"],
          thinking: %{toggle: true}
        )

      refute Map.has_key?(body(model, %{thinking: :high}), "thinking_budget")
    end

    test "thinking_toggle_format :reasoning_enabled" do
      model =
        flagged([thinking_toggle_format: :reasoning_enabled],
          thinking: %{efforts: ["none", "low", "medium", "high"]}
        )

      assert body(model, %{thinking: false})["reasoning"] == %{"enabled" => false}
      assert body(model, %{thinking: :high})["reasoning_effort"] == "high"
    end

    test "output_format :json_object puts the schema in the system prompt" do
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      model = flagged(output_format: :json_object)

      result = body(model, %{output: schema})
      assert result["response_format"] == %{"type" => "json_object"}
      assert [%{"role" => "system", "content" => instruction} | _] = result["messages"]
      assert instruction =~ "Respond with JSON matching this schema"
      assert instruction =~ ~s("city")

      context = Context.new(system: "Be brief.", messages: [Message.new("Hi")])
      [system | _] = body(model, %{output: schema}, context)["messages"]
      assert system["content"] =~ ~r/^Be brief\.\n\nRespond with JSON/
    end

    test "attachment_format :file_url wraps non-image files" do
      context =
        Context.new([
          Message.new(
            role: :user,
            content: [
              Text.new("Read this"),
              Attachment.new(source: {:base64, "pdf"}, media_type: "application/pdf"),
              Attachment.new(source: {:base64, "img"}, media_type: "image/png")
            ]
          )
        ])

      [%{"content" => [_text, file, image]}] =
        body(flagged(attachment_format: :file_url), %{}, context)["messages"]

      assert file == %{
               "type" => "file_url",
               "file_url" => %{"url" => "data:application/pdf;base64,pdf"}
             }

      assert image["type"] == "image_url"
    end

    test "omit drops cache, thinking and strict schemas" do
      model = flagged([omit: [:cache, :thinking, :strict_schema]], thinking: true)
      schema = %{type: "object", properties: %{city: %{type: "string"}}}

      result = body(model, %{cache: :long, thinking: :high, output: schema})

      refute Map.has_key?(result, "prompt_cache_retention")
      refute Map.has_key?(result, "reasoning_effort")
      refute Map.has_key?(result["response_format"]["json_schema"], "strict")
      assert result["response_format"]["type"] == "json_schema"
    end

    test "extra_body merges literal fields" do
      result = body(flagged(extra_body: %{"safe_prompt" => true}), %{})
      assert result["safe_prompt"] == true
    end

    test "thinking_replay_format :reasoning_details captures reasoning_details from the stream" do
      model = flagged(thinking_replay_format: :reasoning_details)
      details = [%{"type" => "reasoning.text", "text" => "hmm"}]
      event = %{"choices" => [%{"delta" => %{"reasoning_details" => details}}]}

      assert {:message, %{private: %{reasoning_details: ^details}}} =
               List.last(OpenAICompletions.handle_event(event, model))

      refute Enum.any?(OpenAICompletions.handle_event(event, @model), &match?({:message, _}, &1))
    end

    test "thinking_replay_format :reasoning_details sends reasoning_details back on assistant messages" do
      details = [%{"type" => "reasoning.text", "text" => "hmm"}]

      context =
        Context.new([
          Message.new("Hi"),
          Message.new(
            role: :assistant,
            content: [Text.new("Hello")],
            private: %{reasoning_details: details}
          ),
          Message.new("Again")
        ])

      [_, assistant, _] =
        body(flagged(thinking_replay_format: :reasoning_details), %{}, context)["messages"]

      assert assistant["reasoning_details"] == details

      [_, plain, _] = body(@model, %{}, context)["messages"]
      refute Map.has_key?(plain, "reasoning_details")
    end

    defp assistant_body(flags, content) do
      context =
        Context.new([
          Message.new("Hi"),
          Message.new(role: :assistant, content: content),
          Message.new("Again")
        ])

      [_, assistant, _] = body(flagged(flags), %{}, context)["messages"]
      assistant
    end

    test "thinking_replay_format :content_chunks sends thinking first, then text parts" do
      assistant =
        assistant_body([thinking_replay_format: :content_chunks], [
          Thinking.new(text: "Let me "),
          Text.new("Hello"),
          Thinking.new(text: "think.", signature: "sig"),
          Text.new(" there")
        ])

      assert assistant["content"] == [
               %{
                 "type" => "thinking",
                 "thinking" => [%{"type" => "text", "text" => "Let me think."}],
                 "signature" => "sig"
               },
               %{"type" => "text", "text" => "Hello"},
               %{"type" => "text", "text" => " there"}
             ]
    end

    test "thinking_replay_format :content_chunks keeps tool calls beside thinking" do
      assistant =
        assistant_body([thinking_replay_format: :content_chunks], [
          Thinking.new(text: "Need the weather."),
          ToolUse.new(id: "aaaaaaaaa", name: "get_weather", input: %{"city" => "London"})
        ])

      assert [%{"type" => "thinking"}] = assistant["content"]
      assert [%{"id" => "aaaaaaaaa"}] = assistant["tool_calls"]
    end

    test "thinking_replay_format :content_chunks leaves messages without thinking as strings" do
      for content <- [
            [Text.new("Hello")],
            [Thinking.new(redacted_data: "opaque"), Text.new("Hello")],
            [Thinking.new(text: ""), Text.new("Hello")]
          ] do
        assert assistant_body([thinking_replay_format: :content_chunks], content)["content"] ==
                 "Hello"
      end
    end

    test "thinking_replay_format :reasoning_content and :reasoning send thinking in that field" do
      content = [
        Thinking.new(text: "Let me "),
        Text.new("Hello"),
        Thinking.new(text: "think."),
        ToolUse.new(id: "call_1", name: "get_weather", input: %{"city" => "London"})
      ]

      for format <- [:reasoning_content, :reasoning] do
        assistant = assistant_body([thinking_replay_format: format], content)

        assert assistant[Atom.to_string(format)] == "Let me think."
        assert assistant["content"] == "Hello"
        assert [%{"id" => "call_1"}] = assistant["tool_calls"]
      end
    end

    test "thinking_replay_format :reasoning_content leaves out the field without thinking" do
      for content <- [
            [Text.new("Hello")],
            [Thinking.new(redacted_data: "opaque"), Text.new("Hello")],
            [Thinking.new(text: ""), Text.new("Hello")]
          ] do
        assistant = assistant_body([thinking_replay_format: :reasoning_content], content)

        refute Map.has_key?(assistant, "reasoning_content")
        assert assistant["content"] == "Hello"
      end
    end

    test "thinking is dropped without a replay format, or with :none" do
      content = [Thinking.new(text: "Hmm."), Text.new("Hello")]

      for flags <- [[], [thinking_replay_format: :none]] do
        assistant = assistant_body(flags, content)

        assert assistant["content"] == "Hello"
        refute Map.has_key?(assistant, "reasoning_content")
        refute Map.has_key?(assistant, "reasoning")
      end
    end
  end

  describe "handle_message/2" do
    defp finish(details) do
      message = Message.new(role: :assistant, content: [], private: %{reasoning_details: details})
      OpenAICompletions.handle_message(message, @model).private.reasoning_details
    end

    defp text(text, extra \\ %{}),
      do: Map.merge(%{"type" => "reasoning.text", "text" => text, "index" => 0}, extra)

    test "joins text fragments and keeps the signature" do
      assert finish([
               text("Count", %{"format" => "anthropic-claude-v1"}),
               text("ing r's"),
               text("", %{"signature" => "sig"})
             ]) == [
               text("Counting r's", %{"format" => "anthropic-claude-v1", "signature" => "sig"})
             ]
    end

    test "a signature closes the text block it signs" do
      assert finish([
               text("one"),
               text("", %{"signature" => "a"}),
               text("two"),
               text("", %{"signature" => "b"})
             ]) == [text("one", %{"signature" => "a"}), text("two", %{"signature" => "b"})]
    end

    test "joins summaries, and keeps encrypted entries and unknown types apart" do
      summary = &%{"type" => "reasoning.summary", "summary" => &1}
      encrypted = &%{"type" => "reasoning.encrypted", "data" => &1, "id" => &1}
      other = %{"type" => "reasoning.other"}

      assert finish([
               summary.("A"),
               summary.("B"),
               encrypted.("x"),
               encrypted.("y"),
               other,
               other,
               text("t")
             ]) == [summary.("AB"), encrypted.("x"), encrypted.("y"), other, other, text("t")]
    end

    test "leaves a message without reasoning_details as it is" do
      message =
        Message.new(role: :assistant, content: [Text.new("Hi")], private: %{other: [1, 2]})

      assert OpenAICompletions.handle_message(message, @model) == message
    end
  end
end
