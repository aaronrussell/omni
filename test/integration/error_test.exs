defmodule Integration.ErrorTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-5-5")
    model
  end

  # -- HTTP errors --

  describe "HTTP errors" do
    test "401 returns error with parsed JSON body" do
      Req.Test.stub(:err_401, fn conn ->
        body = JSON.encode!(%{"error" => %{"message" => "Invalid API key"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, body)
      end)

      assert {:error, {:http_error, 401, %{"error" => _}}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_401}
               )
    end

    test "429 returns error with parsed JSON body" do
      Req.Test.stub(:err_429, fn conn ->
        body = JSON.encode!(%{"error" => %{"message" => "Rate limit exceeded"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, body)
      end)

      assert {:error, {:http_error, 429, _}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_429}
               )
    end

    test "500 returns error with plain text body" do
      Req.Test.stub(:err_500, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_500}
               )
    end
  end

  # -- Transport errors --

  describe "transport errors" do
    test "connection timeout returns {:error, %Req.TransportError{}}" do
      Req.Test.stub(:err_timeout, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_timeout}
               )
    end

    test "connection closed returns {:error, %Req.TransportError{}}" do
      Req.Test.stub(:err_closed, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      assert {:error, %Req.TransportError{reason: :closed}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_closed}
               )
    end
  end

  # -- Auth error --

  describe "auth error" do
    test "nil api_key returns :no_api_key" do
      assert {:error, :no_api_key} = Omni.generate_text(model(), "Hello", api_key: nil)
    end
  end

  # -- Model resolution errors --

  describe "model resolution errors" do
    test "unknown provider returns error" do
      assert {:error, {:unknown_provider, :nonexistent}} =
               Omni.generate_text({:nonexistent, "any"}, "Hello")
    end

    test "unknown model returns error" do
      assert {:error, {:unknown_model, :anthropic, "no-such-model"}} =
               Omni.generate_text({:anthropic, "no-such-model"}, "Hello")
    end

    test "a string reference resolves to its model" do
      Req.Test.stub(:err_string_ref, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, File.read!("test/support/fixtures/anthropic/text.sse"))
      end)

      for ref <- ["anthropic:claude-haiku-5-5", "anthropic/claude-haiku-5-5"] do
        assert {:ok, %Response{}} =
                 Omni.generate_text(ref, "Hello",
                   api_key: "test-key",
                   plug: {Req.Test, :err_string_ref}
                 )
      end
    end

    test "string reference errors" do
      assert {:error, {:invalid_model_ref, "claude-haiku-5-5"}} =
               Omni.generate_text("claude-haiku-5-5", "Hello")

      assert {:error, {:invalid_model_ref, "claude-haiku-5-5"}} =
               Omni.stream_text("claude-haiku-5-5", "Hello")

      assert {:error, {:unknown_provider, "error_test_nope"}} =
               Omni.generate_text("error_test_nope:any", "Hello")

      assert {:error, {:unknown_model, :anthropic, "no-such-model"}} =
               Omni.generate_text("anthropic:no-such-model", "Hello")

      assert {:error, {:invalid_model_ref, "jev-latest"}} =
               Omni.decide("jev-latest", {"state", [q: Omni.predicate("Yes?")]})
    end
  end

  # -- Context coercion --

  describe "context coercion" do
    setup do
      Req.Test.stub(:err_coerce, fn conn ->
        body = File.read!("test/support/fixtures/anthropic/text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok
    end

    test "string context" do
      assert {:ok, %Response{}} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_coerce}
               )
    end

    test "message list context" do
      messages = [Message.new("Hello")]

      assert {:ok, %Response{}} =
               Omni.generate_text(model(), messages,
                 api_key: "test-key",
                 plug: {Req.Test, :err_coerce}
               )
    end

    test "Context struct" do
      context = Context.new("Hello")

      assert {:ok, %Response{}} =
               Omni.generate_text(model(), context,
                 api_key: "test-key",
                 plug: {Req.Test, :err_coerce}
               )
    end
  end

  # -- Truncated stream --

  describe "truncated stream" do
    test "generate_text returns {:error, :incomplete_stream}" do
      Req.Test.stub(:err_truncated, fn conn ->
        body = File.read!("test/support/fixtures/synthetic/anthropic_truncated.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, :incomplete_stream} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_truncated}
               )
    end

    test "stream_text emits :error event with partial content" do
      Req.Test.stub(:err_truncated_stream, fn conn ->
        body = File.read!("test/support/fixtures/synthetic/anthropic_truncated.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, sr} =
        Omni.stream_text(model(), "Hello",
          api_key: "test-key",
          plug: {Req.Test, :err_truncated_stream}
        )

      events = Enum.to_list(sr)
      types = Enum.map(events, &elem(&1, 0))

      assert :error in types
      refute :done in types

      # Partial content was still accumulated
      {_, _, resp} = Enum.find(events, &match?({:error, _, _}, &1))
      assert resp.error == :incomplete_stream
    end
  end

  # -- Stream features --

  describe "stream features" do
    test "text_stream/1 yields the text and complete/1 the response" do
      Req.Test.stub(:err_text_stream, fn conn ->
        body = File.read!("test/support/fixtures/anthropic/text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      opts = [api_key: "test-key", plug: {Req.Test, :err_text_stream}]

      {:ok, sr} = Omni.stream_text(model(), "Hello", opts)
      chunks = sr |> StreamingResponse.text_stream() |> Enum.to_list()
      assert length(chunks) > 1

      {:ok, sr} = Omni.stream_text(model(), "Hello", opts)
      assert {:ok, %Response{message: message}} = StreamingResponse.complete(sr)
      assert [%Omni.Content.Text{text: text}] = message.content
      assert text == Enum.join(chunks)
    end

    test "cancel/1 returns :ok" do
      Req.Test.stub(:err_cancel, fn conn ->
        body = File.read!("test/support/fixtures/anthropic/text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, sr} =
        Omni.stream_text(model(), "Hello",
          api_key: "test-key",
          plug: {Req.Test, :err_cancel}
        )

      assert :ok = StreamingResponse.cancel(sr)
    end

    test "raw: true attaches request/response to final response" do
      Req.Test.stub(:err_raw, fn conn ->
        body = File.read!("test/support/fixtures/anthropic/text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, sr} =
        Omni.stream_text(model(), "Hello",
          api_key: "test-key",
          raw: true,
          plug: {Req.Test, :err_raw}
        )

      assert {:ok, %Response{raw: [{%Req.Request{}, %Req.Response{}}]}} =
               StreamingResponse.complete(sr)
    end
  end
end
