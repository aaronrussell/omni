defmodule Integration.CacheUsageTest do
  use ExUnit.Case, async: true

  alias Omni.Response

  defp stub_fixture(stub_name, fixture_file) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_file)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  describe "Anthropic Messages dialect" do
    test "cache_read_tokens and cache_write_tokens are populated" do
      stub_fixture(:cache_anthropic, "test/support/fixtures/synthetic/anthropic_cache.sse")

      {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :cache_anthropic}
               )

      assert resp.usage.input_tokens == 100
      assert resp.usage.output_tokens == 15
      assert resp.usage.cache_read_tokens == 50
      assert resp.usage.cache_write_tokens == 25
    end
  end

  describe "OpenAI Completions dialect" do
    test "cache_read_tokens populated from prompt_tokens_details" do
      stub_fixture(
        :cache_oai_completions,
        "test/support/fixtures/synthetic/openai_completions_cache.sse"
      )

      {:ok, model} = Omni.get_model(:groq, "llama-3.3-70b-versatile")

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :cache_oai_completions}
               )

      assert resp.usage.input_tokens == 46
      assert resp.usage.output_tokens == 17
      assert resp.usage.cache_read_tokens == 20
      assert resp.usage.cache_write_tokens == 0
    end
  end

  describe "OpenAI Responses dialect" do
    test "cache_read_tokens populated from input_tokens_details" do
      stub_fixture(
        :cache_oai_responses,
        "test/support/fixtures/synthetic/openai_responses_cache.sse"
      )

      {:ok, model} = Omni.get_model(:openai, "gpt-5-mini")

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :cache_oai_responses}
               )

      assert resp.usage.input_tokens == 17
      assert resp.usage.output_tokens == 22
      assert resp.usage.cache_read_tokens == 12
      assert resp.usage.cache_write_tokens == 0
    end
  end

  describe "Google Gemini dialect" do
    test "cache_read_tokens populated from cachedContentTokenCount" do
      stub_fixture(:cache_google, "test/support/fixtures/synthetic/google_cache.sse")

      {:ok, model} = Omni.get_model(:google, "gemini-2.5-flash-lite")

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model, "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :cache_google}
               )

      assert resp.usage.input_tokens == 100
      assert resp.usage.output_tokens == 50
      assert resp.usage.cache_read_tokens == 80
      assert resp.usage.cache_write_tokens == 0
    end
  end
end
