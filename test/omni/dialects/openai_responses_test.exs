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

  describe "build_path/1" do
    test "returns /v1/responses" do
      assert OpenAIResponses.build_path(@model) == "/v1/responses"
    end
  end

  describe "build_body/3" do
    test "simple text message with string content shorthand" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      assert body["model"] == "gpt-4.1-nano"
      assert body["stream"] == true
      assert length(body["input"]) == 1

      [msg] = body["input"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello"
    end

    test "system prompt becomes instructions field" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      assert body["instructions"] == "You are helpful."
      # System should not appear in input
      roles = body["input"] |> Enum.filter(&is_map_key(&1, "role")) |> Enum.map(& &1["role"])
      refute "system" in roles
    end

    test "no system prompt omits instructions" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "instructions")
    end

    test "max_tokens in opts sets max_output_tokens" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, max_tokens: 1024)

      assert body["max_output_tokens"] == 1024
    end

    test "no max_tokens omits max_output_tokens" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "max_output_tokens")
    end

    test "temperature in opts" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, temperature: 0.7)

      assert body["temperature"] == 0.7
    end

    test "no temperature omits key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "temperature")
    end

    test "metadata in opts" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, metadata: %{"user_id" => "123"})

      assert body["metadata"] == %{"user_id" => "123"}
    end

    test "no metadata omits key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "metadata")
    end

    test "cache :long sets prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, cache: :long)

      assert body["prompt_cache_retention"] == "24h"
    end

    test "cache :short omits prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, cache: :short)

      refute Map.has_key?(body, "prompt_cache_retention")
    end

    test "no cache omits prompt_cache_retention" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "tools")
    end

    test "multi-turn conversation" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

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
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      [user_msg] = body["input"]
      assert is_list(user_msg["content"])
      assert length(user_msg["content"]) == 2

      [text_part, image_part] = user_msg["content"]
      assert text_part["type"] == "input_text"
      assert image_part["type"] == "input_image"
    end

    test "streaming is always enabled" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      assert body["stream"] == true
    end

    test "no stream_options key" do
      context = Context.new("Hello")
      {:ok, body} = OpenAIResponses.build_body(@model, context, [])

      refute Map.has_key?(body, "stream_options")
    end
  end

  describe "parse_event/1" do
    test "response.created returns start with model" do
      event = %{
        "type" => "response.created",
        "response" => %{"id" => "resp_123", "model" => "gpt-4.1-nano", "status" => "in_progress"}
      }

      assert {:start, %{model: "gpt-4.1-nano"}} = OpenAIResponses.parse_event(event)
    end

    test "response.output_text.delta returns text_delta" do
      event = %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "Hello"
      }

      assert {:text_delta, %{index: 0, delta: "Hello"}} = OpenAIResponses.parse_event(event)
    end

    test "response.output_item.added with function_call returns tool_use_start" do
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

      assert {:tool_use_start, %{index: 0, id: "call_abc123", name: "get_weather"}} =
               OpenAIResponses.parse_event(event)
    end

    test "response.function_call_arguments.delta returns tool_use_delta" do
      event = %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => "{\"city\""
      }

      assert {:tool_use_delta, %{index: 0, delta: "{\"city\""}} =
               OpenAIResponses.parse_event(event)
    end

    test "response.reasoning_summary_text.delta returns thinking_delta" do
      event = %{
        "type" => "response.reasoning_summary_text.delta",
        "summary_index" => 0,
        "delta" => "Let me think about this..."
      }

      assert {:thinking_delta, %{index: 0, delta: "Let me think about this..."}} =
               OpenAIResponses.parse_event(event)
    end

    test "response.completed with text output returns done with :stop" do
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

      assert {:done, %{stop_reason: :stop, usage: usage}} = OpenAIResponses.parse_event(event)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "response.completed with function_call output returns done with :tool_use" do
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

      assert {:done, %{stop_reason: :tool_use}} = OpenAIResponses.parse_event(event)
    end

    test "response.completed with incomplete status returns done with :length" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "incomplete",
          "output" => [],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 100, "total_tokens" => 110}
        }
      }

      assert {:done, %{stop_reason: :length}} = OpenAIResponses.parse_event(event)
    end

    test "response.output_item.added with non-function_call returns nil" do
      event = %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "message", "role" => "assistant"}
      }

      assert nil == OpenAIResponses.parse_event(event)
    end

    test "unknown event returns nil" do
      assert nil == OpenAIResponses.parse_event(%{"type" => "response.output_text.done"})
    end

    test "completely unknown structure returns nil" do
      assert nil == OpenAIResponses.parse_event(%{"something" => "else"})
    end
  end
end
