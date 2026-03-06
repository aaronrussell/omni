defmodule Integration.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Omni.{Provider, Response}
  alias Omni.Content.Text

  setup_all do
    Provider.load([:opencode])
    :ok
  end

  @anthropic_fixture "test/support/fixtures/sse/opencode_text_anthropic.sse"
  @oair_fixture "test/support/fixtures/sse/opencode_text_oair.sse"
  @oaic_fixture "test/support/fixtures/sse/opencode_text_oaic.sse"
  @google_fixture "test/support/fixtures/sse/opencode_text_google.sse"

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
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
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
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
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
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
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
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and byte_size(text) > 0
    end

    test "model has the correct dialect" do
      assert model("gemini-3-flash").dialect == Omni.Dialects.GoogleGemini
    end
  end
end
