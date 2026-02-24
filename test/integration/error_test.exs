defmodule Integration.ErrorTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message, Response, StreamingResponse}

  @error_fixture "test/support/fixtures/synthetic/anthropic_error.sse"

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
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

  # -- Mid-stream SSE error --

  describe "mid-stream SSE error" do
    test "error event mid-stream returns error from generate_text" do
      Req.Test.stub(:err_midstream, fn conn ->
        body = File.read!(@error_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, "Overloaded"} =
               Omni.generate_text(model(), "Hello",
                 api_key: "test-key",
                 plug: {Req.Test, :err_midstream}
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
  end

  # -- Context coercion --

  describe "context coercion" do
    setup do
      Req.Test.stub(:err_coerce, fn conn ->
        body = File.read!("test/support/fixtures/sse/anthropic_text.sse")

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

  # -- Stream features --

  describe "stream features" do
    test "cancel/1 returns :ok" do
      Req.Test.stub(:err_cancel, fn conn ->
        body = File.read!("test/support/fixtures/sse/anthropic_text.sse")

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
        body = File.read!("test/support/fixtures/sse/anthropic_text.sse")

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
