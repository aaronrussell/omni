defmodule Omni.Dialects.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.OpenAIResponses
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Model, Tool}

  @model Model.new(
           id: "gpt-4.1-nano",
           name: "GPT-4.1 nano",
           provider: Omni.Providers.OpenAI,
           dialect: OpenAIResponses,
           max_output_tokens: 32768
         )

  describe "option_schema/0" do
    test "returns empty map" do
      assert OpenAIResponses.option_schema() == %{}
    end
  end

  describe "handle_path/1" do
    test "returns /v1/responses" do
      assert OpenAIResponses.handle_path(@model, %{}) == "/v1/responses"
    end
  end

  describe "handle_body/3" do
    test "simple text message with string content shorthand" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert body["model"] == "gpt-4.1-nano"
      assert body["stream"] == true
      assert length(body["input"]) == 1

      [msg] = body["input"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello"
    end

    test "system prompt becomes instructions field" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert body["instructions"] == "You are helpful."
      # System should not appear in input
      roles = body["input"] |> Enum.filter(&is_map_key(&1, "role")) |> Enum.map(& &1["role"])
      refute "system" in roles
    end

    test "no system prompt omits instructions" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "instructions")
    end

    test "max_tokens in opts sets max_output_tokens" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{max_tokens: 1024})

      assert body["max_output_tokens"] == 1024
    end

    test "no max_tokens omits max_output_tokens" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "max_output_tokens")
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{temperature: 0.7})

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{metadata: %{"user_id" => "123"}})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "metadata")
    end

    test "cache :long sets prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{cache: :long})

      assert body["prompt_cache_retention"] == "24h"
    end

    test "cache :short omits prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{cache: :short})

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "no cache omits prompt_cache_retention" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "tools with flattened function format" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("What's the weather?")], tools: [tool])
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "function"
      assert encoded_tool["name"] == "get_weather"
      assert encoded_tool["description"] == "Gets the weather"

      assert encoded_tool["parameters"] == %{
               type: "object",
               properties: %{city: %{type: "string"}}
             }

      # No "function" wrapper
      refute Map.has_key?(encoded_tool, "function")
    end

    test "empty tools omits key" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert length(body["input"]) == 3

      roles =
        body["input"]
        |> Enum.filter(&is_map_key(&1, "role"))
        |> Enum.map(& &1["role"])

      assert roles == ["user", "assistant", "user"]
    end

    test "assistant text encodes with output_text content type" do
      msg = Message.new(role: :assistant, content: "Hi there!")
      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      [assistant_msg] = body["input"]
      assert assistant_msg["role"] == "assistant"
      assert [%{"type" => "output_text", "text" => "Hi there!"}] = assistant_msg["content"]
    end

    test "assistant with ToolUse encodes as top-level function_call items" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            ToolUse.new(id: "call_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert [item] = body["input"]
      assert item["type"] == "function_call"
      assert item["call_id"] == "call_01"
      assert item["name"] == "get_weather"
      assert item["arguments"] == ~s({"city":"London"})
    end

    test "assistant with text and ToolUse produces message + function_call items" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            Text.new("Let me check the weather."),
            ToolUse.new(id: "call_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert length(body["input"]) == 2

      [assistant_msg, tool_item] = body["input"]
      assert assistant_msg["role"] == "assistant"
      assert tool_item["type"] == "function_call"
      assert tool_item["name"] == "get_weather"
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert [assistant_msg] = body["input"]
      assert assistant_msg["role"] == "assistant"

      assert [%{"type" => "output_text", "text" => "Here's the answer."}] =
               assistant_msg["content"]
    end

    test "user with ToolResult encodes as function_call_output items" do
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert [item] = body["input"]
      assert item["type"] == "function_call_output"
      assert item["call_id"] == "call_01"
      assert item["output"] == "Sunny, 22°C"
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert length(body["input"]) == 2

      [tool_item, user_msg] = body["input"]
      assert tool_item["type"] == "function_call_output"
      assert tool_item["call_id"] == "call_01"

      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Thanks!"
    end

    test "image base64 encodes as data URI in input_image" do
      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, "abc123"}, media_type: "image/png")]
        )

      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      [block] = user_msg["content"]
      assert block["type"] == "input_image"
      assert block["image_url"] == "data:image/png;base64,abc123"
    end

    test "image URL encodes directly in input_image" do
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      [block] = user_msg["content"]
      assert block["type"] == "input_image"
      assert block["image_url"] == "https://example.com/image.png"
    end

    test "text and image encode as content array with input_text and input_image" do
      msg =
        Message.new(
          role: :user,
          content: [
            Text.new("What's in this image?"),
            Attachment.new(source: {:base64, "data"}, media_type: "image/jpeg")
          ]
        )

      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      assert is_list(user_msg["content"])
      assert length(user_msg["content"]) == 2

      [text_part, image_part] = user_msg["content"]
      assert text_part["type"] == "input_text"
      assert image_part["type"] == "input_image"
    end

    test "PDF base64 encodes as input_file with data URL" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "pdf-data"}, media_type: "application/pdf")
          ]
        )

      context = Context.new([msg])
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      [block] = user_msg["content"]
      assert block["type"] == "input_file"
      assert block["file_data"] == "data:application/pdf;base64,pdf-data"
    end

    test "PDF URL encodes as input_file with file_url" do
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      [block] = user_msg["content"]
      assert block["type"] == "input_file"
      assert block["file_url"] == "https://example.com/doc.pdf"
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
      body = OpenAIResponses.handle_body(@model, context, %{})

      [user_msg] = body["input"]
      [block] = user_msg["content"]
      assert block["type"] == "input_file"
      assert block["file_data"] == "data:application/xml;base64,xml-data"
    end

    test "streaming is always enabled" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      assert body["stream"] == true
    end

    test "no stream_options key" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "stream_options")
    end
  end

  describe "handle_body/3 thinking" do
    @reasoning_model Model.new(
                       id: "o3-mini",
                       name: "o3-mini",
                       provider: Omni.Providers.OpenAI,
                       dialect: OpenAIResponses,
                       max_output_tokens: 32768,
                       reasoning: true
                     )

    test "thinking: true sets reasoning with high effort and summary auto" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@reasoning_model, context, %{thinking: true})

      assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    end

    test "effort levels map correctly, :max caps to high" do
      context = Context.new("Hello")

      for {level, expected} <- [low: "low", medium: "medium", high: "high", max: "high"] do
        body = OpenAIResponses.handle_body(@reasoning_model, context, %{thinking: level})

        assert body["reasoning"]["effort"] == expected,
               "expected #{expected} for level #{level}"

        assert body["reasoning"]["summary"] == "auto"
      end
    end

    test "budget is ignored" do
      context = Context.new("Hello")

      body =
        OpenAIResponses.handle_body(@reasoning_model, context, %{
          thinking: [effort: :medium, budget: 10_000]
        })

      assert body["reasoning"]["effort"] == "medium"
      refute Map.has_key?(body["reasoning"], "budget")
    end

    test "thinking: false is no-op" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@reasoning_model, context, %{thinking: false})

      refute Map.has_key?(body, "reasoning")
    end

    test "thinking: :none is no-op" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@reasoning_model, context, %{thinking: :none})

      refute Map.has_key?(body, "reasoning")
    end

    test "non-reasoning model ignores thinking option" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{thinking: :high})

      refute Map.has_key?(body, "reasoning")
    end

    test "nil thinking is no-op" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@reasoning_model, context, %{})

      refute Map.has_key?(body, "reasoning")
    end
  end

  describe "handle_event/1" do
    test "response.created returns message with model" do
      event = %{
        "type" => "response.created",
        "response" => %{"id" => "resp_123", "model" => "gpt-4.1-nano", "status" => "in_progress"}
      }

      assert [{:message, %{model: "gpt-4.1-nano"}}] = OpenAIResponses.handle_event(event)
    end

    test "response.output_text.delta returns block_delta" do
      event = %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "Hello"
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Hello"}}] =
               OpenAIResponses.handle_event(event)
    end

    test "response.output_item.added with function_call returns block_start" do
      event = %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_abc123",
          "name" => "get_weather",
          "arguments" => ""
        }
      }

      assert [
               {:block_start,
                %{type: :tool_use, index: 0, id: "call_abc123", name: "get_weather"}}
             ] =
               OpenAIResponses.handle_event(event)
    end

    test "response.function_call_arguments.delta returns block_delta" do
      event = %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => "{\"city\""
      }

      assert [{:block_delta, %{type: :tool_use, index: 0, delta: "{\"city\""}}] =
               OpenAIResponses.handle_event(event)
    end

    test "response.reasoning_summary_text.delta returns block_delta" do
      event = %{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => 0,
        "summary_index" => 0,
        "delta" => "Let me think about this..."
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Let me think about this..."}}] =
               OpenAIResponses.handle_event(event)
    end

    test "response.completed with text output returns message with :stop" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "output" => [
            %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello!"}]}
          ],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        }
      }

      assert [{:message, %{stop_reason: :stop, usage: usage}}] =
               OpenAIResponses.handle_event(event)

      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "response.completed with function_call output returns message with :tool_use" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "output" => [
            %{"type" => "function_call", "call_id" => "call_abc123", "name" => "get_weather"}
          ],
          "usage" => %{"input_tokens" => 25, "output_tokens" => 15, "total_tokens" => 40}
        }
      }

      assert [{:message, %{stop_reason: :tool_use}}] = OpenAIResponses.handle_event(event)
    end

    test "response.completed with incomplete status returns message with :length" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "incomplete",
          "output" => [],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 100, "total_tokens" => 110}
        }
      }

      assert [{:message, %{stop_reason: :length}}] = OpenAIResponses.handle_event(event)
    end

    test "response.completed with failed status returns message with :error" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "failed",
          "output" => [],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 0, "total_tokens" => 10}
        }
      }

      assert [{:message, %{stop_reason: :error}}] = OpenAIResponses.handle_event(event)
    end

    test "response.output_item.added with non-function_call returns empty list" do
      event = %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "message", "role" => "assistant"}
      }

      assert [] == OpenAIResponses.handle_event(event)
    end

    test "unknown event returns empty list" do
      assert [] == OpenAIResponses.handle_event(%{"type" => "response.output_text.done"})
    end

    test "completely unknown structure returns empty list" do
      assert [] == OpenAIResponses.handle_event(%{"something" => "else"})
    end
  end

  describe "handle_body/3 output" do
    test "output schema sets text format with json_schema" do
      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      body = OpenAIResponses.handle_body(@model, context, %{output: schema})

      format = body["text"]["format"]
      assert format["type"] == "json_schema"
      assert format["name"] == "output"
      assert format["strict"] == true
      assert format["schema"] == schema
    end

    test "no output omits text key" do
      context = Context.new("Hello")
      body = OpenAIResponses.handle_body(@model, context, %{})

      refute Map.has_key?(body, "text")
    end
  end
end
