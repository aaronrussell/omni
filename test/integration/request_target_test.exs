defmodule Integration.RequestTargetTest do
  # Asserts where each built-in provider sends its requests and how it
  # authenticates them: host, path, and auth header. Guards base URL and
  # auth refactors, which the per-provider tests (fixture-driven, never
  # inspecting the request) would not catch.
  use ExUnit.Case, async: true

  @fixtures "test/support/fixtures"

  # {provider_id, model_id, fixture, host, path, expected_headers}
  @cases [
    {:alibaba, "qwen3.6-plus", "sse/alibaba_text.sse", "dashscope-intl.aliyuncs.com",
     "/compatible-mode/v1/chat/completions", [{"authorization", "Bearer test-key"}]},
    {:anthropic, "claude-haiku-4-5", "sse/anthropic_text.sse", "api.anthropic.com",
     "/v1/messages", [{"x-api-key", "test-key"}, {"anthropic-version", "2023-06-01"}]},
    {:google, "gemini-2.5-flash", "sse/google_text.sse", "generativelanguage.googleapis.com",
     "/v1beta/models/gemini-2.5-flash:streamGenerateContent", [{"x-goog-api-key", "test-key"}]},
    {:groq, "llama-3.3-70b-versatile", "sse/groq_text.sse", "api.groq.com",
     "/openai/v1/chat/completions", [{"authorization", "Bearer test-key"}]},
    {:moonshotai, "kimi-k2.6", "sse/moonshot_text.sse", "api.moonshot.ai", "/v1/chat/completions",
     [{"authorization", "Bearer test-key"}]},
    {:nearai, "zai-org/GLM-5.1-FP8", "sse/nearai_text.sse", "cloud-api.near.ai",
     "/v1/chat/completions", [{"authorization", "Bearer test-key"}]},
    {:ollama_cloud, "deepseek-v4-flash", "ndjson/ollama_text.ndjson", "ollama.com", "/api/chat",
     [{"authorization", "Bearer test-key"}]},
    {:openai, "gpt-4.1-mini", "sse/openai_text.sse", "api.openai.com", "/v1/responses",
     [{"authorization", "Bearer test-key"}]},
    {:opencode, "claude-haiku-4-5", "sse/opencode_text_anthropic.sse", "opencode.ai",
     "/zen/v1/messages", [{"x-api-key", "test-key"}]},
    {:opencode, "gpt-5.2", "sse/opencode_text_oair.sse", "opencode.ai", "/zen/v1/responses",
     [{"authorization", "Bearer test-key"}]},
    {:opencode, "kimi-k2.5", "sse/opencode_text_oaic.sse", "opencode.ai",
     "/zen/v1/chat/completions", [{"authorization", "Bearer test-key"}]},
    {:opencode, "gemini-3-flash", "sse/opencode_text_google.sse", "opencode.ai",
     "/zen/v1/models/gemini-3-flash:streamGenerateContent", [{"x-goog-api-key", "test-key"}]},
    {:openrouter, "openai/gpt-4.1-mini", "sse/openrouter_text.sse", "openrouter.ai",
     "/api/v1/chat/completions", [{"authorization", "Bearer test-key"}]},
    {:venice, "qwen3-6-27b", "sse/venice_text.sse", "api.venice.ai", "/api/v1/chat/completions",
     [{"authorization", "Bearer test-key"}]},
    {:zai, "glm-4.7-flash", "sse/zai_text.sse", "api.z.ai", "/api/paas/v4/chat/completions",
     [{"authorization", "Bearer test-key"}]}
  ]

  for {provider_id, model_id, fixture, host, path, expected_headers} <- @cases do
    test "#{provider_id}/#{model_id} → #{host}#{path}" do
      provider_id = unquote(provider_id)
      stub = :"target_#{provider_id}_#{unquote(model_id)}"
      fixture = Path.join(@fixtures, unquote(fixture))
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:request, conn.host, conn.request_path, conn.req_headers})
        # ollama.com labels its NDJSON stream plain application/json
        content_type =
          cond do
            provider_id == :ollama_cloud -> "application/json"
            String.ends_with?(fixture, ".ndjson") -> "application/x-ndjson"
            true -> "text/event-stream"
          end

        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.send_resp(200, File.read!(fixture))
      end)

      {:ok, model} = Omni.get_model(provider_id, unquote(model_id))

      assert {:ok, _response} =
               Omni.generate_text(model, "Hello", api_key: "test-key", plug: {Req.Test, stub})

      assert_received {:request, host, path, headers}
      assert host == unquote(host)
      assert path == unquote(path)

      for header <- unquote(expected_headers) do
        assert header in headers
      end
    end
  end
end
