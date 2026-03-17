defmodule Integration.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Omni.{Provider, Response}
  alias Omni.Content.{Text, ToolUse}

  setup_all do
    Provider.load([:opencode])
    :ok
  end

  @anthropic_fixture "test/support/fixtures/sse/opencode_text_anthropic.sse"
  @oair_fixture "test/support/fixtures/sse/opencode_text_oair.sse"
  @oaic_fixture "test/support/fixtures/sse/opencode_text_oaic.sse"
  @google_fixture "test/support/fixtures/sse/opencode_text_google.sse"
  @kimi_tool_use_fixture "test/support/fixtures/cases/opencode_kimi-k2-5_tool_use.sse"

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model(id) do
    {:ok, model} = Omni.get_model(:opencode, id)
    model
  end

  describe "Anthropic Messages dialect (claude-haiku-4-5)" do
    test "generate_text returns a text response" do
      stub_fixture(:oc_anthropic, @anthropic_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model("claude-haiku-4-5"), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :oc_anthropic}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end

    test "model has the correct dialect" do
      assert model("claude-haiku-4-5").dialect == Omni.Dialects.AnthropicMessages
    end
  end

  describe "OpenAI Responses dialect (gpt-5.2)" do
    test "generate_text returns a text response" do
      stub_fixture(:oc_oair, @oair_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model("gpt-5.2"), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :oc_oair}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end

    test "model has the correct dialect" do
      assert model("gpt-5.2").dialect == Omni.Dialects.OpenAIResponses
    end
  end

  describe "OpenAI Completions dialect (kimi-k2.5)" do
    test "generate_text returns a text response" do
      stub_fixture(:oc_oaic, @oaic_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model("kimi-k2.5"), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :oc_oaic}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end

    test "tool_use returns tool name and input when provider sends id on every chunk" do
      stub_fixture(:oc_kimi_tool, @kimi_tool_use_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model("kimi-k2.5"), "What's the weather in London?",
                 api_key: "test-key",
                 max_steps: 1,
                 plug: {Req.Test, :oc_kimi_tool}
               )

      assert resp.stop_reason == :tool_use
      assert [%Text{}, %ToolUse{} = tool_use] = resp.message.content
      assert tool_use.name == "get_weather"
      assert tool_use.input == %{"location" => "London"}
    end

    test "model has the correct dialect" do
      assert model("kimi-k2.5").dialect == Omni.Dialects.OpenAICompletions
    end
  end

  describe "Google Gemini dialect (gemini-3-flash)" do
    test "generate_text returns a text response" do
      stub_fixture(:oc_google, @google_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model("gemini-3-flash"), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :oc_google}
               )

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.turn.usage.input_tokens > 0
      assert resp.turn.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end

    test "model has the correct dialect" do
      assert model("gemini-3-flash").dialect == Omni.Dialects.GoogleGemini
    end
  end
end
