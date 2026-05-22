defmodule Integration.NearAITest do
  use ExUnit.Case, async: true

  alias Omni.{Response, StreamingResponse}
  alias Omni.Content.Text

  defp model do
    {:ok, model} = Omni.get_model(:nearai, "zai-org/GLM-5.1-FP8")
    model
  end

  defp sse_body do
    """
    data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":0,"model":"zai-org/GLM-5.1-FP8","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":0,"model":"zai-org/GLM-5.1-FP8","choices":[{"index":0,"delta":{"content":"Hello from NEAR AI"},"finish_reason":null}]}

    data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":0,"model":"zai-org/GLM-5.1-FP8","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}}

    data: [DONE]

    """
  end

  describe "generate_text/3 — text" do
    test "sends an OpenAI-compatible request to NEAR AI Cloud" do
      test_pid = self()

      Req.Test.stub(:int_nearai_text, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:captured_request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           JSON.decode!(body)}
        )

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body())
      end)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Write a haiku about private inference.",
                 api_key: "test-key",
                 max_tokens: 12,
                 cache: :long,
                 plug: {Req.Test, :int_nearai_text}
               )

      assert_received {:captured_request, "/v1/chat/completions", ["Bearer test-key"], captured}

      assert captured["model"] == "zai-org/GLM-5.1-FP8"
      assert captured["stream"] == true
      assert captured["stream_options"] == %{"include_usage" => true}
      assert captured["max_tokens"] == 12
      refute Map.has_key?(captured, "max_completion_tokens")
      refute Map.has_key?(captured, "prompt_cache_retention")

      assert resp.stop_reason == :stop
      assert resp.message.role == :assistant
      assert resp.usage.input_tokens == 5
      assert resp.usage.output_tokens == 4
      assert [%Text{text: "Hello from NEAR AI"}] = resp.message.content
    end
  end

  describe "stream_text/3 — text streaming" do
    test "streams text deltas" do
      Req.Test.stub(:int_nearai_stream, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body())
      end)

      {:ok, sr} =
        Omni.stream_text(model(), "Hello",
          api_key: "test-key",
          plug: {Req.Test, :int_nearai_stream}
        )

      assert ["Hello from NEAR AI"] = Enum.to_list(StreamingResponse.text_stream(sr))
    end
  end
end
