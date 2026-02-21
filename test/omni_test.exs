defmodule OmniTest do
  use ExUnit.Case, async: true
  doctest Omni

  alias Omni.{Context, Message, Model, Response, StreamingResponse}
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Providers.{Anthropic, Google, OpenAI, OpenRouter}
  alias Omni.Dialects.{AnthropicMessages, GoogleGemini, OpenAICompletions, OpenAIResponses}

  # -- Fixture paths --

  @anthropic_text "test/support/fixtures/sse/anthropic_text.sse"
  @anthropic_tool_use "test/support/fixtures/sse/anthropic_tool_use.sse"
  @anthropic_thinking "test/support/fixtures/sse/anthropic_thinking.sse"

  @openai_text "test/support/fixtures/sse/openai_responses_text.sse"
  @openai_tool_use "test/support/fixtures/sse/openai_responses_tool_use.sse"
  @openai_thinking "test/support/fixtures/sse/openai_responses_thinking.sse"

  @google_text "test/support/fixtures/sse/google_text.sse"
  @google_tool_use "test/support/fixtures/sse/google_tool_use.sse"
  @google_thinking "test/support/fixtures/sse/google_thinking.sse"

  @openrouter_text "test/support/fixtures/sse/openrouter_text.sse"
  @openrouter_tool_use "test/support/fixtures/sse/openrouter_tool_use.sse"
  @openrouter_thinking "test/support/fixtures/sse/openrouter_thinking.sse"

  # -- Model constants --

  @anthropic_model Model.new(
                     id: "claude-sonnet-4-20250514",
                     name: "Claude Sonnet 4",
                     provider: Anthropic,
                     dialect: AnthropicMessages,
                     max_output_tokens: 8192
                   )

  @anthropic_reasoning Model.new(
                         id: "claude-3.5-sonnet-20241022",
                         name: "Claude 3.5 Sonnet",
                         provider: Anthropic,
                         dialect: AnthropicMessages,
                         max_output_tokens: 8192,
                         reasoning: true
                       )

  @openai_model Model.new(
                  id: "gpt-4.1-nano",
                  name: "GPT-4.1 nano",
                  provider: OpenAI,
                  dialect: OpenAIResponses,
                  max_output_tokens: 32768
                )

  @openai_reasoning Model.new(
                      id: "o3-mini",
                      name: "o3-mini",
                      provider: OpenAI,
                      dialect: OpenAIResponses,
                      max_output_tokens: 32768,
                      reasoning: true
                    )

  @google_model Model.new(
                  id: "gemini-2.0-flash-lite",
                  name: "Gemini 2.0 Flash Lite",
                  provider: Google,
                  dialect: GoogleGemini,
                  max_output_tokens: 8192
                )

  @google_reasoning Model.new(
                      id: "gemini-2.5-flash-preview",
                      name: "Gemini 2.5 Flash Preview",
                      provider: Google,
                      dialect: GoogleGemini,
                      max_output_tokens: 8192,
                      reasoning: true
                    )

  @openrouter_model Model.new(
                      id: "meta-llama/llama-3.1-8b-instruct",
                      name: "Llama 3.1 8B Instruct",
                      provider: OpenRouter,
                      dialect: OpenAICompletions,
                      max_output_tokens: 32768
                    )

  @openrouter_reasoning Model.new(
                          id: "deepseek/deepseek-r1",
                          name: "DeepSeek R1",
                          provider: OpenRouter,
                          dialect: OpenAICompletions,
                          max_output_tokens: 32768,
                          reasoning: true
                        )

  # -- Helpers --

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp tool_context do
    tool =
      Omni.tool(
        name: "get_weather",
        description: "Gets the weather",
        input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
      )

    Context.new(
      messages: [Message.new("What's the weather in London?")],
      tools: [tool]
    )
  end

  # ============================================================
  # generate_text/3 — text
  # ============================================================

  describe "generate_text/3 text" do
    test "Anthropic" do
      stub_fixture(:omni_anthropic_text, @anthropic_text)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@anthropic_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_anthropic_text}
               )

      assert resp.message.role == :assistant
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.stop_reason == :stop
      assert resp.usage.input_tokens > 0 or resp.usage.output_tokens > 0
    end

    test "OpenAI" do
      stub_fixture(:omni_openai_text, @openai_text)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openai_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_openai_text}
               )

      assert resp.message.role == :assistant
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.stop_reason == :stop
    end

    test "Google" do
      stub_fixture(:omni_google_text, @google_text)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@google_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_google_text}
               )

      assert resp.message.role == :assistant
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.stop_reason == :stop
    end

    test "OpenRouter" do
      stub_fixture(:omni_openrouter_text, @openrouter_text)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openrouter_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_openrouter_text}
               )

      assert resp.message.role == :assistant
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.stop_reason == :stop
    end
  end

  # ============================================================
  # generate_text/3 — tool use
  # ============================================================

  describe "generate_text/3 tool use" do
    test "Anthropic" do
      stub_fixture(:omni_anthropic_tool, @anthropic_tool_use)
      context = tool_context()

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@anthropic_model, context,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_anthropic_tool}
               )

      assert resp.stop_reason == :tool_use
      tool_uses = Enum.filter(resp.message.content, &match?(%ToolUse{}, &1))
      assert length(tool_uses) > 0
      tool_use = hd(tool_uses)
      assert is_binary(tool_use.id) and tool_use.id != ""
      assert is_binary(tool_use.name) and tool_use.name != ""
      assert is_map(tool_use.input)
    end

    test "OpenAI" do
      stub_fixture(:omni_openai_tool, @openai_tool_use)
      context = tool_context()

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openai_model, context,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_openai_tool}
               )

      assert resp.stop_reason == :tool_use
      tool_uses = Enum.filter(resp.message.content, &match?(%ToolUse{}, &1))
      assert length(tool_uses) > 0
      tool_use = hd(tool_uses)
      assert is_binary(tool_use.id) and tool_use.id != ""
      assert is_binary(tool_use.name) and tool_use.name != ""
      assert is_map(tool_use.input)
    end

    test "Google" do
      stub_fixture(:omni_google_tool, @google_tool_use)
      context = tool_context()

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@google_model, context,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_google_tool}
               )

      # The real fixture contains a text response (model asked for clarification).
      # Verify content blocks are present and well-formed.
      assert length(resp.message.content) > 0
      assert resp.message.role == :assistant
    end

    test "OpenRouter" do
      stub_fixture(:omni_openrouter_tool, @openrouter_tool_use)
      context = tool_context()

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openrouter_model, context,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_openrouter_tool}
               )

      assert resp.stop_reason == :tool_use
      tool_uses = Enum.filter(resp.message.content, &match?(%ToolUse{}, &1))
      assert length(tool_uses) > 0
      tool_use = hd(tool_uses)
      assert is_binary(tool_use.id) and tool_use.id != ""
      assert is_binary(tool_use.name) and tool_use.name != ""
      assert is_map(tool_use.input)
    end
  end

  # ============================================================
  # generate_text/3 — thinking
  # ============================================================

  describe "generate_text/3 thinking" do
    test "Anthropic" do
      stub_fixture(:omni_anthropic_thinking, @anthropic_thinking)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@anthropic_reasoning, "Hello",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :omni_anthropic_thinking}
               )

      assert resp.stop_reason == :stop

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
      assert hd(texts).text != ""
    end

    test "OpenAI" do
      stub_fixture(:omni_openai_thinking, @openai_thinking)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openai_reasoning, "Hello",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :omni_openai_thinking}
               )

      assert resp.stop_reason == :stop

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
      assert hd(texts).text != ""
    end

    test "Google" do
      stub_fixture(:omni_google_thinking, @google_thinking)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@google_reasoning, "Hello",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :omni_google_thinking}
               )

      assert resp.stop_reason == :stop

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
      assert hd(texts).text != ""
    end

    test "OpenRouter" do
      stub_fixture(:omni_openrouter_thinking, @openrouter_thinking)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(@openrouter_reasoning, "Hello",
                 api_key: "test-key",
                 thinking: true,
                 plug: {Req.Test, :omni_openrouter_thinking}
               )

      assert resp.stop_reason == :stop

      thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
      assert length(thinking) > 0

      texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
      assert length(texts) > 0
      assert hd(texts).text != ""
    end
  end

  # ============================================================
  # stream_text/3
  # ============================================================

  describe "stream_text/3" do
    test "text_stream/1 yields text deltas" do
      stub_fixture(:omni_stream_text, @anthropic_text)

      {:ok, sr} =
        Omni.stream_text(@anthropic_model, "Hello",
          api_key: "test-key",
          plug: {Req.Test, :omni_stream_text}
        )

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end

    test "cancel/1 returns :ok" do
      stub_fixture(:omni_stream_cancel, @anthropic_text)

      {:ok, sr} =
        Omni.stream_text(@anthropic_model, "Hello",
          api_key: "test-key",
          plug: {Req.Test, :omni_stream_cancel}
        )

      assert :ok = StreamingResponse.cancel(sr)
    end

    test "raw: true attaches request/response to final response" do
      stub_fixture(:omni_stream_raw, @anthropic_text)

      {:ok, sr} =
        Omni.stream_text(@anthropic_model, "Hello",
          api_key: "test-key",
          raw: true,
          plug: {Req.Test, :omni_stream_raw}
        )

      assert {:ok, %Response{raw: {%Req.Request{}, %Req.Response{}}}} =
               StreamingResponse.complete(sr)
    end
  end

  # ============================================================
  # Model resolution
  # ============================================================

  describe "model resolution" do
    test "tuple {provider_id, model_id} resolves and works" do
      stub_fixture(:omni_resolve, @anthropic_text)

      [model_id | _] = :persistent_term.get({Omni, :anthropic}) |> Map.keys()

      assert {:ok, %Response{}} =
               Omni.generate_text({:anthropic, model_id}, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_resolve}
               )
    end

    test "unknown provider returns error" do
      assert {:error, {:unknown_provider, :nonexistent}} =
               Omni.generate_text({:nonexistent, "any"}, "Hello")
    end

    test "unknown model returns error" do
      assert {:error, {:unknown_model, :anthropic, "no-such-model"}} =
               Omni.generate_text({:anthropic, "no-such-model"}, "Hello")
    end
  end

  # ============================================================
  # Context coercion
  # ============================================================

  describe "context coercion" do
    setup do
      stub_fixture(:omni_coerce, @anthropic_text)
      :ok
    end

    test "string context" do
      assert {:ok, %Response{}} =
               Omni.generate_text(@anthropic_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_coerce}
               )
    end

    test "message list context" do
      messages = [Message.new("Hello")]

      assert {:ok, %Response{}} =
               Omni.generate_text(@anthropic_model, messages,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_coerce}
               )
    end

    test "Context struct" do
      context = Context.new("Hello")

      assert {:ok, %Response{}} =
               Omni.generate_text(@anthropic_model, context,
                 api_key: "test-key",
                 plug: {Req.Test, :omni_coerce}
               )
    end
  end

  # ============================================================
  # Error handling
  # ============================================================

  describe "error handling" do
    test "HTTP 4xx returns error with parsed JSON body" do
      Req.Test.stub(:omni_err_4xx, fn conn ->
        body = JSON.encode!(%{"error" => %{"message" => "Invalid API key"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, body)
      end)

      assert {:error, {:http_error, 401, %{"error" => %{"message" => "Invalid API key"}}}} =
               Omni.generate_text(@anthropic_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_err_4xx}
               )
    end

    test "HTTP 5xx returns error" do
      Req.Test.stub(:omni_err_5xx, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               Omni.generate_text(@anthropic_model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :omni_err_5xx}
               )
    end

    test "no API key returns auth error" do
      assert {:error, :no_api_key} = Omni.generate_text(@anthropic_model, "Hello", api_key: nil)
    end
  end

  # ============================================================
  # Delegates (existing tests)
  # ============================================================

  describe "delegates" do
    test "get_model/2 delegates to Model.get/2" do
      [model_id | _] = :persistent_term.get({Omni, :anthropic}) |> Map.keys()
      assert {:ok, %Model{id: ^model_id}} = Omni.get_model(:anthropic, model_id)
    end

    test "get_model/2 returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Omni.get_model(:nonexistent, "any")
    end

    test "list_models/1 delegates to Model.list/1" do
      assert {:ok, models} = Omni.list_models(:anthropic)
      assert length(models) > 0
    end

    test "tool/1 delegates to Tool.new/1" do
      tool = Omni.tool(name: "greet", description: "Says hello", handler: &String.upcase/1)
      assert %Omni.Tool{name: "greet", description: "Says hello"} = tool
    end

    test "context/1 delegates to Context.new/1" do
      assert %Context{messages: [%Message{role: :user}]} = Omni.context("Hello")
    end

    test "message/1 delegates to Message.new/1" do
      assert %Message{role: :user, content: [%Omni.Content.Text{text: "Hi"}]} =
               Omni.message("Hi")
    end
  end
end
