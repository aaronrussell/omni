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

  describe "handle_path/2" do
    test "embeds model ID in path" do
      path = GoogleGemini.handle_path(@model, %{})
      assert path =~ "gemini-2.0-flash-lite"
    end

    test "uses v1beta path" do
      path = GoogleGemini.handle_path(@model, %{})
      assert path == "/v1beta/models/gemini-2.0-flash-lite:streamGenerateContent?alt=sse"
    end
  end

  describe "handle_body/3" do
    test "simple text message" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      assert [msg] = body["contents"]
      assert msg["role"] == "user"
      assert [%{"text" => "Hello"}] = msg["parts"]
    end

    test "no model key in body" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body, "model")
    end

    test "no stream key in body" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body, "stream")
    end

    test "assistant role maps to model" do
      msg = Message.new(role: :assistant, content: "Hi there!")
      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

      assert length(body["contents"]) == 3
      roles = Enum.map(body["contents"], & &1["role"])
      assert roles == ["user", "model", "user"]
    end

    test "system prompt encodes as systemInstruction" do
      context = Context.new(system: "You are helpful.", messages: [Message.new("Hi")])
      body = GoogleGemini.handle_body(@model, context, %{})

      assert %{"parts" => [%{"text" => "You are helpful."}]} = body["systemInstruction"]
    end

    test "no system prompt omits systemInstruction" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body, "systemInstruction")
    end

    test "no max_tokens omits maxOutputTokens from generationConfig" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body["generationConfig"], "maxOutputTokens")
    end

    test "max_tokens in opts sets maxOutputTokens" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{max_tokens: 1024})

      assert body["generationConfig"]["maxOutputTokens"] == 1024
    end

    test "temperature in generationConfig" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{temperature: 0.7})

      assert body["generationConfig"]["temperature"] == 0.7
    end

    test "no temperature omits key from generationConfig" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body["generationConfig"], "temperature")
    end

    test "cache option is no-op" do
      context = Context.new("Hello")
      body_short = GoogleGemini.handle_body(@model, context, %{cache: :short})
      body_long = GoogleGemini.handle_body(@model, context, %{cache: :long})
      body_nil = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

      assert [%{"functionDeclarations" => [decl]}] = body["tools"]
      assert decl["name"] == "get_weather"
      assert decl["description"] == "Gets the weather"
      assert decl["parameters"] == %{type: "object", properties: %{city: %{type: "string"}}}
    end

    test "empty tools omits key" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "nil tools omits key" do
      context = Context.new(messages: [Message.new("Hello")], tools: nil)
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body, "tools")
    end

    test "Text content encodes as text part" do
      msg = Message.new(role: :user, content: [Text.new("Hello")])
      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["fileData"]["fileUri"] == "https://example.com/doc.pdf"
      assert part["fileData"]["mimeType"] == "application/pdf"
    end

    test "text/plain base64 attachment encodes as inlineData" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "dGV4dA=="}, media_type: "text/plain")
          ]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["inlineData"]["mimeType"] == "text/plain"
      assert part["inlineData"]["data"] == "dGV4dA=="
    end

    test "uncommon media type (application/xml) encodes as inlineData without crash" do
      msg =
        Message.new(
          role: :user,
          content: [
            Attachment.new(source: {:base64, "xml-data"}, media_type: "application/xml")
          ]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["inlineData"]["mimeType"] == "application/xml"
      assert part["inlineData"]["data"] == "xml-data"
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
      body = GoogleGemini.handle_body(@model, context, %{})

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
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["functionResponse"]["name"] == "get_weather"
      assert part["functionResponse"]["response"]["result"] == "Sunny, 22°C"
    end

    test "Thinking block with text encodes as thought part" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            Thinking.new(text: "Let me think...", signature: "sig123"),
            Text.new("Here's the answer.")
          ]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]

      assert [thought_part, text_part] = encoded["parts"]
      assert thought_part["text"] == "Let me think..."
      assert thought_part["thought"] == true
      assert thought_part["thoughtSignature"] == "sig123"
      assert text_part["text"] == "Here's the answer."
    end

    test "Thinking block without signature omits thoughtSignature" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: "reasoning", signature: nil)]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part == %{"text" => "reasoning", "thought" => true}
    end

    test "Thinking block with signature only (no text) encodes as standalone thoughtSignature" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: nil, signature: "sig_hidden")]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      assert [%{"thoughtSignature" => "sig_hidden"}] = encoded["parts"]
    end

    test "Thinking block with no text and no signature is skipped" do
      msg =
        Message.new(
          role: :assistant,
          content: [Thinking.new(text: nil), Text.new("answer")]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      assert [%{"text" => "answer"}] = encoded["parts"]
    end

    test "Text block with signature encodes thoughtSignature" do
      msg =
        Message.new(
          role: :user,
          content: [Text.new(text: "hello", signature: "sig_text")]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["text"] == "hello"
      assert part["thoughtSignature"] == "sig_text"
    end

    test "Text block without signature omits thoughtSignature" do
      msg = Message.new(role: :user, content: [Text.new("hello")])
      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part == %{"text" => "hello"}
    end

    test "ToolUse block with signature encodes thoughtSignature" do
      msg =
        Message.new(
          role: :assistant,
          content: [
            ToolUse.new(
              id: "call_01",
              name: "get_weather",
              input: %{"city" => "London"},
              signature: "sig_fc"
            )
          ]
        )

      context = Context.new([msg])
      body = GoogleGemini.handle_body(@model, context, %{})

      [encoded] = body["contents"]
      [part] = encoded["parts"]
      assert part["functionCall"] == %{"name" => "get_weather", "args" => %{"city" => "London"}}
      assert part["thoughtSignature"] == "sig_fc"
    end
  end

  describe "handle_body/3 thinking — Gemini 2.5 (budget path)" do
    @reasoning_model Model.new(
                       id: "gemini-2.5-flash-preview",
                       name: "Gemini 2.5 Flash Preview",
                       provider: Omni.Providers.Google,
                       dialect: GoogleGemini,
                       max_output_tokens: 8192,
                       reasoning: true
                     )

    test "thinking: :high sets thinkingBudget" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@reasoning_model, context, %{thinking: :high})

      assert body["generationConfig"]["thinkingConfig"] == %{
               "thinkingBudget" => 8192,
               "includeThoughts" => true
             }
    end

    test "thinkingConfig is nested inside generationConfig" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@reasoning_model, context, %{thinking: :high})

      assert Map.has_key?(body["generationConfig"], "thinkingConfig")
      refute Map.has_key?(body, "thinkingConfig")
    end

    test "effort levels map to budget integers, :max uses dynamic (-1)" do
      context = Context.new("Hello")

      for {level, expected} <- [
            low: 2048,
            medium: 4096,
            high: 8192,
            xhigh: 16384,
            max: -1
          ] do
        body = GoogleGemini.handle_body(@reasoning_model, context, %{thinking: level})

        assert body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == expected,
               "expected budget #{expected} for level #{level}"

        assert body["generationConfig"]["thinkingConfig"]["includeThoughts"] == true
        refute Map.has_key?(body["generationConfig"]["thinkingConfig"], "thinkingLevel")
      end
    end

    test "explicit budget sets thinkingBudget directly" do
      context = Context.new("Hello")

      body =
        GoogleGemini.handle_body(@reasoning_model, context, %{
          thinking: %{effort: :high, budget: 8192}
        })

      assert body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 8192
      assert body["generationConfig"]["thinkingConfig"]["includeThoughts"] == true
      refute Map.has_key?(body["generationConfig"]["thinkingConfig"], "thinkingLevel")
    end

    test "thinking: false sets thinkingBudget to 0" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@reasoning_model, context, %{thinking: false})

      assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}
    end

    test "non-reasoning model ignores thinking option" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{thinking: :high})

      refute Map.has_key?(body, "thinkingConfig")
    end

    test "nil thinking is no-op" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@reasoning_model, context, %{})

      refute Map.has_key?(body, "thinkingConfig")
    end
  end

  describe "handle_body/3 thinking — Gemini 3 (level path, shifted)" do
    @gemini3_model Model.new(
                     id: "gemini-3-pro-preview",
                     name: "Gemini 3 Pro Preview",
                     provider: Omni.Providers.Google,
                     dialect: GoogleGemini,
                     max_output_tokens: 8192,
                     reasoning: true
                   )

    test "effort levels shift down onto Gemini's 4-level scale" do
      context = Context.new("Hello")

      for {level, expected} <- [
            low: "minimal",
            medium: "low",
            high: "medium",
            xhigh: "high",
            max: "high"
          ] do
        body = GoogleGemini.handle_body(@gemini3_model, context, %{thinking: level})

        assert body["generationConfig"]["thinkingConfig"]["thinkingLevel"] == expected,
               "expected #{expected} for level #{level}"

        assert body["generationConfig"]["thinkingConfig"]["includeThoughts"] == true
        refute Map.has_key?(body["generationConfig"]["thinkingConfig"], "thinkingBudget")
      end
    end

    test "effort map form uses the same shifted mapping" do
      context = Context.new("Hello")

      body = GoogleGemini.handle_body(@gemini3_model, context, %{thinking: %{effort: :max}})

      assert body["generationConfig"]["thinkingConfig"]["thinkingLevel"] == "high"
    end

    test "explicit budget still wins on Gemini 3" do
      context = Context.new("Hello")

      body =
        GoogleGemini.handle_body(@gemini3_model, context, %{
          thinking: %{effort: :high, budget: 4096}
        })

      assert body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 4096
      refute Map.has_key?(body["generationConfig"]["thinkingConfig"], "thinkingLevel")
    end

    test "thinking: false sets thinkingBudget to 0" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@gemini3_model, context, %{thinking: false})

      assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}
    end
  end

  describe "handle_event/1" do
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
             ] = GoogleGemini.handle_event(event)

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

      # Dialect reports :stop; StreamingResponse infers :tool_use from blocks.
      assert [
               {:message, %{stop_reason: :stop}},
               {:block_start, result}
             ] = GoogleGemini.handle_event(event)

      assert result.type == :tool_use
      assert result.name == "get_weather"
      assert result.input == %{"city" => "London"}
      assert is_integer(result.index) and result.index > 0
      assert is_binary(result.id)
      assert String.starts_with?(result.id, "google_fc_")
    end

    test "STOP maps to :stop" do
      event = %{
        "candidates" => [
          %{"finishReason" => "STOP", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :stop}}] = GoogleGemini.handle_event(event)
    end

    test "MAX_TOKENS maps to :length" do
      event = %{
        "candidates" => [
          %{"finishReason" => "MAX_TOKENS", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :length}}] = GoogleGemini.handle_event(event)
    end

    for reason <- ~w(SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII) do
      test "#{reason} maps to :refusal" do
        event = %{
          "candidates" => [
            %{"finishReason" => unquote(reason), "index" => 0}
          ]
        }

        assert [{:message, %{stop_reason: :refusal}}] = GoogleGemini.handle_event(event)
      end
    end

    test "unknown finishReason maps to :stop" do
      event = %{
        "candidates" => [
          %{"finishReason" => "UNKNOWN_REASON", "index" => 0}
        ]
      }

      assert [{:message, %{stop_reason: :stop}}] = GoogleGemini.handle_event(event)
    end

    test "usage emits message with normalized usage" do
      event = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      assert [{:message, %{usage: usage}}] = GoogleGemini.handle_event(event)
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
               GoogleGemini.handle_event(event)

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
             ] = GoogleGemini.handle_event(event)
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
               GoogleGemini.handle_event(event)
    end

    test "unknown event returns empty list" do
      assert [] == GoogleGemini.handle_event(%{"type" => "something_else"})
    end

    test "error event returns error delta" do
      event = %{
        "error" => %{
          "code" => 429,
          "status" => "RESOURCE_EXHAUSTED",
          "message" => "You've exceeded the rate limit."
        }
      }

      assert [{:error, "You've exceeded the rate limit."}] = GoogleGemini.handle_event(event)
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

      assert [{:message, %{stop_reason: :stop}}] = GoogleGemini.handle_event(event)
    end

    test "thought part emits thinking block_delta" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Let me reason...", "thought" => true}],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [{:block_delta, %{type: :thinking, index: 0, delta: "Let me reason..."}}] =
               GoogleGemini.handle_event(event)
    end

    test "thought part with thoughtSignature emits signature" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Let me reason...", "thought" => true, "thoughtSignature" => "sig_t1"}
              ],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [
               {:block_delta,
                %{type: :thinking, index: 0, delta: "Let me reason...", signature: "sig_t1"}}
             ] =
               GoogleGemini.handle_event(event)
    end

    test "text part with thoughtSignature emits signature" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Answer text", "thoughtSignature" => "sig_x1"}],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [{:block_delta, %{type: :text, index: 0, delta: "Answer text", signature: "sig_x1"}}] =
               GoogleGemini.handle_event(event)
    end

    test "functionCall with thoughtSignature emits signature" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "search", "args" => %{"q" => "test"}},
                  "thoughtSignature" => "sig_fc1"
                }
              ],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [{:block_start, %{type: :tool_use, name: "search", signature: "sig_fc1"}}] =
               GoogleGemini.handle_event(event)
    end

    test "multiple function calls in one event emit unique indices" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "get_weather", "args" => %{"city" => "London"}},
                  "thoughtSignature" => "sig_fc1"
                },
                %{
                  "functionCall" => %{"name" => "get_time", "args" => %{"city" => "London"}},
                  "thoughtSignature" => "sig_fc2"
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
               {:message, %{stop_reason: :stop}},
               {:block_start, first},
               {:block_start, second}
             ] = GoogleGemini.handle_event(event)

      assert first.type == :tool_use
      assert is_integer(first.index)
      assert first.name == "get_weather"
      assert first.signature == "sig_fc1"

      assert second.type == :tool_use
      assert is_integer(second.index)
      assert second.name == "get_time"
      assert second.signature == "sig_fc2"

      # Indices must be unique (monotonic integers)
      assert first.index != second.index
      # IDs must be unique
      assert first.id != second.id
    end

    test "thought and text parts in same event emit both types" do
      event = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking...", "thought" => true},
                %{"text" => "Answer here"}
              ],
              "role" => "model"
            },
            "index" => 0
          }
        ]
      }

      assert [
               {:block_delta, %{type: :thinking, delta: "Thinking..."}},
               {:block_delta, %{type: :text, delta: "Answer here"}}
             ] = GoogleGemini.handle_event(event)
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
             ] = GoogleGemini.handle_event(event)
    end
  end

  describe "handle_body/3 output" do
    test "output schema sets responseMimeType and responseSchema in generationConfig" do
      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      body = GoogleGemini.handle_body(@model, context, %{output: schema})

      assert body["generationConfig"]["responseMimeType"] == "application/json"
      assert body["generationConfig"]["responseSchema"] == schema
    end

    test "output schema does not inject additionalProperties" do
      context = Context.new("Hello")
      schema = %{type: "object", properties: %{city: %{type: "string"}}}
      body = GoogleGemini.handle_body(@model, context, %{output: schema})

      refute Map.has_key?(body["generationConfig"]["responseSchema"], :additionalProperties)
    end

    test "no output omits responseMimeType and responseSchema" do
      context = Context.new("Hello")
      body = GoogleGemini.handle_body(@model, context, %{})

      refute Map.has_key?(body["generationConfig"], "responseMimeType")
      refute Map.has_key?(body["generationConfig"], "responseSchema")
    end
  end
end
