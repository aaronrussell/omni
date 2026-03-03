defmodule Omni.Dialects.OllamaChatTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.OllamaChat
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Model}

  @model Model.new(
           id: "qwen3.5:4b",
           name: "qwen3.5:4b",
           provider: Omni.Providers.Ollama,
           dialect: OllamaChat
         )

  @reasoning_model Model.new(
                     id: "qwen3.5:4b",
                     name: "qwen3.5:4b",
                     provider: Omni.Providers.Ollama,
                     dialect: OllamaChat,
                     reasoning: true
                   )

  describe "option_schema/0" do
    test "returns empty map" do
      assert OllamaChat.option_schema() == %{}
    end
  end

  describe "handle_path/2" do
    test "returns /api/chat" do
      assert OllamaChat.handle_path(@model, %{}) == "/api/chat"
    end
  end

  describe "handle_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{})

      assert body["model"] == "qwen3.5:4b"
      assert body["stream"] == true
      assert length(body["messages"]) == 1

      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello"
    end

    test "system prompt as first message with system role" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      body = OllamaChat.handle_body(@model, context, %{})

      [system_msg | rest] = body["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
      assert length(rest) == 1
    end

    test "no system prompt omits system message" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{})

      roles = Enum.map(body["messages"], & &1["role"])
      refute "system" in roles
    end

    test "max_tokens maps to options.num_predict" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{max_tokens: 1024})

      assert body["options"]["num_predict"] == 1024
    end

    test "temperature maps to options.temperature" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{temperature: 0.7})

      assert body["options"]["temperature"] == 0.7
    end

    test "no options omits options key" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{})

      refute Map.has_key?(body, "options")
    end

    test "assistant message with text" do
      context =
        Context.new(
          messages: [
            Message.new("Hello"),
            Message.new(role: :assistant, content: [Text.new(text: "Hi there")])
          ]
        )

      body = OllamaChat.handle_body(@model, context, %{})

      [_user, assistant] = body["messages"]
      assert assistant["role"] == "assistant"
      assert assistant["content"] == "Hi there"
    end

    test "assistant message with tool use" do
      tool_use = ToolUse.new(id: "tc_1", name: "get_weather", input: %{"city" => "London"})

      context =
        Context.new(
          messages: [
            Message.new("Weather?"),
            Message.new(role: :assistant, content: [tool_use])
          ]
        )

      body = OllamaChat.handle_body(@model, context, %{})

      [_user, assistant] = body["messages"]
      assert assistant["role"] == "assistant"
      [tc] = assistant["tool_calls"]
      assert tc["function"]["name"] == "get_weather"
      assert tc["function"]["arguments"] == %{"city" => "London"}
      assert tc["id"] == "tc_1"
    end

    test "tool result as separate tool role message" do
      tool_result =
        ToolResult.new(
          tool_use_id: "tc_1",
          name: "get_weather",
          content: [Text.new(text: "72°F")]
        )

      context =
        Context.new(
          messages: [
            Message.new(role: :user, content: [tool_result])
          ]
        )

      body = OllamaChat.handle_body(@model, context, %{})

      [tool_msg] = body["messages"]
      assert tool_msg["role"] == "tool"
      assert tool_msg["content"] == "72°F"
    end

    test "tools encoded as function type" do
      tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("Hello")], tools: [tool])
      body = OllamaChat.handle_body(@model, context, %{})

      [t] = body["tools"]
      assert t["type"] == "function"
      assert t["function"]["name"] == "get_weather"
      assert t["function"]["description"] == "Gets the weather"

      assert t["function"]["parameters"] == %{
               type: "object",
               properties: %{city: %{type: "string"}}
             }
    end

    test "no tools omits tools key" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "user message with image attachment" do
      attachment =
        Attachment.new(source: {:base64, "abc123"}, media_type: "image/png")

      context =
        Context.new(
          messages: [
            Message.new(role: :user, content: [Text.new(text: "What is this?"), attachment])
          ]
        )

      body = OllamaChat.handle_body(@model, context, %{})

      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "What is this?"
      assert msg["images"] == ["abc123"]
    end

    test "thinking :high sets think to true on reasoning model" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@reasoning_model, context, %{thinking: :high})

      assert body["think"] == true
    end

    test "thinking effort level sets think value" do
      context = Context.new("Hello")

      body = OllamaChat.handle_body(@reasoning_model, context, %{thinking: :low})
      assert body["think"] == "low"

      body = OllamaChat.handle_body(@reasoning_model, context, %{thinking: :medium})
      assert body["think"] == "medium"
    end

    test "thinking false explicitly sets think to false" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@reasoning_model, context, %{thinking: false})

      assert body["think"] == false
    end

    test "thinking on non-reasoning model omits think key" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{thinking: :high})

      refute Map.has_key?(body, "think")
    end

    test "output schema sets format" do
      schema = %{type: "object", properties: %{name: %{type: "string"}}}
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{output: schema})

      assert body["format"] == schema
    end

    test "no output omits format key" do
      context = Context.new("Hello")
      body = OllamaChat.handle_body(@model, context, %{})

      refute Map.has_key?(body, "format")
    end

    test "assistant message with thinking block" do
      context =
        Context.new(
          messages: [
            Message.new("Hello"),
            Message.new(
              role: :assistant,
              content: [
                Thinking.new(text: "Let me think..."),
                Text.new(text: "Here's my answer")
              ]
            )
          ]
        )

      body = OllamaChat.handle_body(@model, context, %{})

      [_user, assistant] = body["messages"]
      assert assistant["role"] == "assistant"
      assert assistant["content"] == "Here's my answer"
      assert assistant["thinking"] == "Let me think..."
    end
  end

  describe "handle_event/1" do
    test "first chunk with model" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => "Hello"},
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      assert {:message, %{model: "qwen3.5:4b"}} in deltas
      assert {:block_delta, %{type: :text, index: 0, delta: "Hello"}} in deltas
    end

    test "text content delta" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => "world"},
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      assert {:block_delta, %{type: :text, index: 0, delta: "world"}} in deltas
    end

    test "empty content produces no block_delta" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => ""},
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      refute Enum.any?(deltas, fn {type, _} -> type == :block_delta end)
    end

    test "thinking content delta" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => "", "thinking" => "Let me think"},
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      assert {:block_delta, %{type: :thinking, index: 0, delta: "Let me think"}} in deltas
    end

    test "tool calls in event" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_abc",
              "function" => %{
                "name" => "get_weather",
                "arguments" => %{"city" => "London"}
              }
            }
          ]
        },
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      assert {:block_start, data} =
               Enum.find(deltas, fn {type, _} -> type == :block_start end)

      assert data.type == :tool_use
      assert data.id == "call_abc"
      assert data.name == "get_weather"
      assert data.input == %{"city" => "London"}
    end

    test "tool calls without id generates one" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "function" => %{
                "name" => "get_weather",
                "arguments" => %{"city" => "Paris"}
              }
            }
          ]
        },
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      assert {:block_start, data} =
               Enum.find(deltas, fn {type, _} -> type == :block_start end)

      assert data.type == :tool_use
      assert is_binary(data.id) and String.starts_with?(data.id, "ollama_tc_")
    end

    test "done event with stop reason and usage" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => ""},
        "done" => true,
        "done_reason" => "stop",
        "prompt_eval_count" => 20,
        "eval_count" => 50
      }

      deltas = OllamaChat.handle_event(event)

      assert {:message, data} = Enum.find(deltas, fn {type, _} -> type == :message end)
      assert data.stop_reason == :stop
      assert data.usage == %{"input_tokens" => 20, "output_tokens" => 50}
    end

    test "done_reason length maps to :length" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => ""},
        "done" => true,
        "done_reason" => "length",
        "prompt_eval_count" => 10,
        "eval_count" => 100
      }

      deltas = OllamaChat.handle_event(event)

      assert {:message, data} = Enum.find(deltas, fn {type, _} -> type == :message end)
      assert data.stop_reason == :length
    end

    test "unknown events return empty list" do
      assert [] = OllamaChat.handle_event(%{"unknown" => "event"})
    end

    test "multiple tool calls in one event" do
      event = %{
        "model" => "qwen3.5:4b",
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "get_weather",
                "arguments" => %{"city" => "London"}
              }
            },
            %{
              "id" => "call_2",
              "function" => %{
                "name" => "get_weather",
                "arguments" => %{"city" => "Paris"}
              }
            }
          ]
        },
        "done" => false
      }

      deltas = OllamaChat.handle_event(event)

      tool_starts = Enum.filter(deltas, fn {type, _} -> type == :block_start end)
      assert length(tool_starts) == 2

      names = Enum.map(tool_starts, fn {:block_start, data} -> data.name end)
      assert "get_weather" in names
    end
  end
end
