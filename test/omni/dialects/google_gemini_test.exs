defmodule Omni.Dialects.GoogleGeminiTest do
  use ExUnit.Case, async: true

  alias Omni.Dialects.GoogleGemini
  alias Omni.Content.{Text, Thinking, ToolUse, ToolResult, Attachment}
  alias Omni.{Context, Message, Model, Tool}

  @model Model.new(
           id: "gemini-2.0-flash-lite",
           name: "Gemini 2.0 Flash Lite",
           provider: Omni.Providers.Google,
           dialect: GoogleGemini,
           max_output_tokens: 8192
         )

  describe "option_schema/0" do
    test "returns empty map" do
      assert GoogleGemini.option_schema() == %{}
    end
  end

  describe "build_path/1" do
    test "embeds model ID in path" do
      path = GoogleGemini.build_path(@model)
      assert path =~ "gemini-2.0-flash-lite"
    end

    test "includes ?alt=sse query param" do
      path = GoogleGemini.build_path(@model)
      assert path == "/v1beta/models/gemini-2.0-flash-lite:streamGenerateContent?alt=sse"
    end
  end

  describe "build_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      assert [msg] = body["contents"]
      assert msg["role"] == "user"
      assert [%{"text" => "Hello"}] = msg["parts"]
    end

    test "no model key in body" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body, "model")
    end

    test "no stream key in body" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body, "stream")
    end

    test "assistant role maps to model" do
      msg = Message.new(role: :assistant, content: "Hi there!")
      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      assert encoded["role"] == "model"
    end

    test "multi-turn conversation preserves order and roles" do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: "Hi there!"),
        Message.new(role: :user, content: "How are you?")
      ]

      context = Context.new(messages)
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      assert length(body["contents"]) == 3
      roles = Enum.map(body["contents"], & &1["role"])
      assert roles == ["user", "model", "user"]
    end

    test "system prompt encodes as systemInstruction" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      assert %{"parts" => [%{"text" => "You are helpful."}]} = body["systemInstruction"]
    end

    test "no system prompt omits systemInstruction" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body, "systemInstruction")
    end

    test "no max_tokens omits maxOutputTokens from generationConfig" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body["generationConfig"], "maxOutputTokens")
    end

    test "max_tokens in opts sets maxOutputTokens" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, max_tokens: 1024)

      assert body["generationConfig"]["maxOutputTokens"] == 1024
    end

    test "temperature in generationConfig" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, temperature: 0.7)

      assert body["generationConfig"]["temperature"] == 0.7
    end

    test "no temperature omits key from generationConfig" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body["generationConfig"], "temperature")
    end

    test "cache option is no-op" do
      context = Context.new("Hello")
      {:ok, body_short} = GoogleGemini.build_body(@model, context, cache: :short)
      {:ok, body_long} = GoogleGemini.build_body(@model, context, cache: :long)
      {:ok, body_nil} = GoogleGemini.build_body(@model, context, [])

      assert body_short == body_nil
      assert body_long == body_nil
    end

    test "tools with functionDeclarations wrapper" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      context = Context.new(messages: [Message.new("What's the weather?")], tools: [tool])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      assert [%{"functionDeclarations" => [decl]}] = body["tools"]
      assert decl["name"] == "get_weather"
      assert decl["description"] == "Gets the weather"
      assert decl["parameters"] == %{type: "object", properties: %{city: %{type: "string"}}}
    end

    test "empty tools omits key" do
      context = Context.new("Hello")
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body, "tools")
    end

    test "nil tools omits key" do
      context = Context.new(messages: [Message.new("Hello")], tools: nil)
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      refute Map.has_key?(body, "tools")
    end

    test "Text content encodes as text part" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      assert [%{"text" => "Hello"}] = encoded["parts"]
    end

    test "base64 image attachment encodes as inlineData" do
      msg =
        Message.new(
          role: :user,
          content: [Attachment.new(source: {:base64, "abc123"}, media_type: "image/png")]
        )

      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["inlineData"]["mimeType"] == "image/png"
      assert part["inlineData"]["data"] == "abc123"
    end

    test "URL image attachment encodes as fileData" do
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
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["fileData"]["fileUri"] == "https://example.com/image.png"
      assert part["fileData"]["mimeType"] == "image/png"
    end

    test "base64 PDF attachment encodes as inlineData" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "pdfdata"}, media_type: "application/pdf")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["inlineData"]["mimeType"] == "application/pdf"
      assert part["inlineData"]["data"] == "pdfdata"
    end

    test "URL PDF attachment encodes as fileData" do
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
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["fileData"]["fileUri"] == "https://example.com/doc.pdf"
      assert part["fileData"]["mimeType"] == "application/pdf"
    end

    test "ToolUse encodes as functionCall" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            ToolUse.new(id: "call_01", name: "get_weather", input: %{"city" => "London"})
          ]
        )

      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["functionCall"]["name"] == "get_weather"
      assert part["functionCall"]["args"] == %{"city" => "London"}
    end

    test "ToolResult encodes as functionResponse" do
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
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["functionResponse"]["name"] == "get_weather"
      assert part["functionResponse"]["response"]["result"] == "Sunny, 22°C"
    end

    test "Thinking block is skipped" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            Thinking.new(text: "Let me think...", signature: "sig123"),
            Text.new("Here's the answer.")
          ]
        )

      context = Context.new([msg])
      {:ok, body} = GoogleGemini.build_body(@model, context, [])

      [encoded] = body["contents"]
      assert [%{"text" => "Here's the answer."}] = encoded["parts"]
    end
  end

  describe "parse_event/1" do
    test "text content emits message with usage and block_delta" do
      event = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hello"}], "role" => "model"},
            "finishReason" => nil,
            "index" => 0
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 5,
          "candidatesTokenCount" => 1,
          "totalTokenCount" => 6
        }
      }

      assert [
               {:message, %{usage: usage}},
               {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
             ] = GoogleGemini.parse_event(event)

      assert usage["input_tokens"] == 5
      assert usage["output_tokens"] == 1
    end

    test "function call emits message and block_start with generated ID and complete input" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{"city" => "London"}
                  }
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ]
      }

      assert [
               {:message, %{stop_reason: :tool_use}},
               {:block_start, result}
             ] = GoogleGemini.parse_event(event)

      assert result.type == :tool_use
      assert result.name == "get_weather"
      assert result.input == %{"city" => "London"}
      assert result.index == 0
      assert is_binary(result.id)
      assert String.starts_with?(result.id, "google_fc_")
    end

    test "STOP maps to :stop" do
      event = %{
        "candidates" => [
          %{"finishReason" => "STOP", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :stop}}] = GoogleGemini.parse_event(event)
    end

    test "MAX_TOKENS maps to :length" do
      event = %{
        "candidates" => [
          %{"finishReason" => "MAX_TOKENS", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :length}}] = GoogleGemini.parse_event(event)
    end

    test "SAFETY maps to :content_filter" do
      event = %{
        "candidates" => [
          %{"finishReason" => "SAFETY", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :content_filter}}] = GoogleGemini.parse_event(event)
    end

    test "RECITATION maps to :content_filter" do
      event = %{
        "candidates" => [
          %{"finishReason" => "RECITATION", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :content_filter}}] = GoogleGemini.parse_event(event)
    end

    test "usage emits message with normalized usage" do
      event = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      assert [{:message, %{usage: usage}}] = GoogleGemini.parse_event(event)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "finishReason with usageMetadata emits combined message" do
      event = %{
        "candidates" => [
          %{"finishReason" => "STOP", "index" => 0}
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      assert [{:message, %{stop_reason: :stop, usage: usage}}] =
               GoogleGemini.parse_event(event)

      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 5
    end

    test "text and finishReason in same event emits both" do
      event = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Final words"}], "role" => "model"},
            "finishReason" => "STOP",
            "index" => 0
          }
        ]
      }

      assert [
               {:message, %{stop_reason: :stop}},
               {:block_delta, %{type: :text, delta: "Final words"}}
             ] = GoogleGemini.parse_event(event)
    end

    test "functionCall and empty text emits only block_start" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => ""},
                %{"functionCall" => %{"name" => "search", "args" => %{"q" => "test"}}}
              ],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [{:block_start, %{type: :tool_use, name: "search"}}] =
               GoogleGemini.parse_event(event)
    end

    test "unknown event returns empty list" do
      assert [] == GoogleGemini.parse_event(%{"type" => "something_else"})
    end

    test "empty text with finishReason emits only message" do
      event = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => ""}], "role" => "model"},
            "finishReason" => "STOP",
            "index" => 0
          }
        ]
      }

      assert [{:message, %{stop_reason: :stop}}] = GoogleGemini.parse_event(event)
    end

    test "modelVersion is extracted into message" do
      event = %{
        "modelVersion" => "gemini-2.0-flash-lite",
        "usageMetadata" => %{
          "promptTokenCount" => 5,
          "candidatesTokenCount" => 1,
          "totalTokenCount" => 6
        },
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hi"}], "role" => "model"},
            "index" => 0
          }
        ]
      }

      assert [
               {:message, %{model: "gemini-2.0-flash-lite", usage: _}},
               {:block_delta, %{type: :text, delta: "Hi"}}
             ] = GoogleGemini.parse_event(event)
    end
  end
end
