defmodule Omni.RequestTest do
  use ExUnit.Case, async: true

  alias Omni.Request

  defmodule DummyDialect do
    @moduledoc false
    @behaviour Omni.Dialect

    @impl true
    def option_schema, do: %{}

    @impl true
    def compat_schema, do: %{}

    @impl true
    def auth, do: :bearer

    @impl true
    def handle_path(_model, _opts), do: "/dummy"

    @impl true
    def handle_body(model, _context, opts) do
      %{"model" => model.id, "max_tokens" => opts[:max_tokens]}
    end

    @impl true
    def handle_event(%{"type" => "message_start"}, _model), do: [{:message, %{model: "test"}}]
    def handle_event(%{"type" => "delta", "text" => t}, _model), do: [{:block_delta, %{delta: t}}]
    def handle_event(_, _model), do: []
  end

  defmodule HeaderAuthDialect do
    @moduledoc false
    @behaviour Omni.Dialect

    @impl true
    def option_schema, do: %{}

    @impl true
    def compat_schema, do: %{}

    @impl true
    def auth, do: {:header, "x-api-key"}

    @impl true
    def handle_path(_model, _opts), do: "/dummy"

    @impl true
    def handle_body(_model, _context, _opts), do: %{}

    @impl true
    def handle_event(_, _model), do: []
  end

  defmodule AugmentingModule do
    @moduledoc false
    @behaviour Omni.Provider

    @impl true
    def modify_body(body, model, _context, _opts), do: Map.put(body, "modified", model.id)

    @impl true
    def modify_request(req, provider, _opts) do
      {:ok, Req.Request.put_header(req, "x-provider", to_string(provider.id))}
    end
  end

  @provider %Omni.Provider{
    id: :request_test,
    base_url: "https://api.test.com/v1",
    api_key: {:system, "TEST_PROVIDER_KEY"},
    auth: :dialect,
    headers: %{"x-custom" => "from-config"},
    dialects: %{text: [DummyDialect]}
  }

  defp provider(attrs), do: struct!(@provider, attrs)

  defp make_model(provider \\ @provider, dialect \\ DummyDialect) do
    Omni.Model.new(
      id: "test-model",
      name: "Test Model",
      provider: provider,
      dialects: %{text: dialect},
      max_output_tokens: 2048
    )
  end

  describe "validate/2" do
    test "merges provider values with call-site opts" do
      model = make_model()

      {:ok, opts} =
        Request.validate(model, api_key: "sk-test", max_tokens: 1024, temperature: 0.7)

      assert opts.api_key == "sk-test"
      assert opts.base_url == "https://api.test.com/v1"
      assert opts[:max_tokens] == 1024
      assert opts[:temperature] == 0.7
    end

    test "api_key: call-site wins" do
      model = make_model()

      {:ok, opts} = Request.validate(model, api_key: "from-call")
      assert opts.api_key == "from-call"
    end

    test "api_key: provider value otherwise" do
      model = make_model()

      {:ok, opts} = Request.validate(model, [])
      assert opts.api_key == {:system, "TEST_PROVIDER_KEY"}
    end

    test "base_url override via opts" do
      model = make_model()

      {:ok, opts} = Request.validate(model, base_url: "https://custom.api.com")
      assert opts.base_url == "https://custom.api.com"
    end

    test "provider struct fields other than base_url, api_key and headers are not options" do
      model = make_model()

      {:ok, opts} = Request.validate(model, [])
      refute Map.has_key?(opts, :dialects)
      refute Map.has_key?(opts, :auth)
    end

    test "plug extraction" do
      model = make_model()
      plug = {Plug.Test, []}

      {:ok, opts} = Request.validate(model, plug: plug)
      assert opts.plug == plug
    end

    test "timeout defaults to 300_000" do
      model = make_model()

      {:ok, opts} = Request.validate(model, [])
      assert opts.timeout == 300_000
    end

    test "inference opts pass through" do
      model = make_model()

      {:ok, opts} = Request.validate(model, max_tokens: 2048, thinking: :high, cache: :short)
      assert opts[:max_tokens] == 2048
      assert opts[:thinking] == :high
      assert opts[:cache] == :short
    end

    test "headers merge additively: provider then call-site" do
      model = make_model()

      {:ok, opts} = Request.validate(model, headers: %{"x-call" => "from-call"})

      assert opts.headers["x-custom"] == "from-config"
      assert opts.headers["x-call"] == "from-call"
    end

    test "unknown keys rejected" do
      model = make_model()

      assert {:error, {:unknown_options, [:temperture]}} =
               Request.validate(model, temperture: 0.7)
    end

    test "max_tokens optional (nil when not provided)" do
      model = make_model()

      {:ok, opts} = Request.validate(model, [])
      assert opts[:max_tokens] == nil
    end

    test "temperature accepts integer" do
      model = make_model()

      {:ok, opts} = Request.validate(model, temperature: 0)
      assert opts[:temperature] == 0
    end

    test "temperature accepts float" do
      model = make_model()

      {:ok, opts} = Request.validate(model, temperature: 0.5)
      assert opts[:temperature] == 0.5
    end

    test "thinking accepts true" do
      model = make_model()

      assert {:ok, %{thinking: true}} = Request.validate(model, thinking: true)
    end

    test "thinking rejects :none" do
      model = make_model()

      assert {:error, _} = Request.validate(model, thinking: :none)
    end

    test "thinking accepts boolean false" do
      model = make_model()

      {:ok, opts} = Request.validate(model, thinking: false)
      assert opts[:thinking] == false
    end

    test "thinking accepts effort atom" do
      model = make_model()

      {:ok, opts} = Request.validate(model, thinking: :high)
      assert opts[:thinking] == :high
    end

    test "thinking accepts :xhigh effort" do
      model = make_model()

      {:ok, opts} = Request.validate(model, thinking: :xhigh)
      assert opts[:thinking] == :xhigh
    end

    test "thinking accepts keyword list (converted to map by Peri)" do
      model = make_model()

      {:ok, opts} = Request.validate(model, thinking: [effort: :high, budget: 10000])
      assert opts[:thinking].effort == :high
      assert opts[:thinking].budget == 10000
    end

    test "thinking rejects invalid value" do
      model = make_model()

      assert {:error, _} = Request.validate(model, thinking: "invalid")
    end

    test "cache accepts :short" do
      model = make_model()

      {:ok, opts} = Request.validate(model, cache: :short)
      assert opts[:cache] == :short
    end

    test "cache accepts :long" do
      model = make_model()

      {:ok, opts} = Request.validate(model, cache: :long)
      assert opts[:cache] == :long
    end

    test "cache rejects invalid value" do
      model = make_model()

      assert {:error, _} = Request.validate(model, cache: :invalid)
    end

    test "max_tokens rejects non-integer" do
      model = make_model()

      assert {:error, _} = Request.validate(model, max_tokens: "big")
    end

    test "output accepts map" do
      model = make_model()
      schema = %{type: :object, properties: %{name: %{type: :string}}}

      {:ok, opts} = Request.validate(model, output: schema)
      assert opts[:output] == schema
    end

    test "output rejects non-map" do
      model = make_model()

      assert {:error, _} = Request.validate(model, output: "not a map")
    end

    test "dialect option_schema merge overrides universal schema" do
      # Create a dialect that overrides max_tokens with a default
      defmodule OverrideDialect do
        @moduledoc false
        @behaviour Omni.Dialect

        @impl true
        def option_schema, do: %{max_tokens: {:integer, {:default, 4096}}}

        @impl true
        def compat_schema, do: %{}

        @impl true
        def auth, do: :bearer

        @impl true
        def handle_path(_model, _opts), do: "/override"

        @impl true
        def handle_body(_model, _context, _opts), do: %{}

        @impl true
        def handle_event(_, _model), do: []
      end

      model = make_model(@provider, OverrideDialect)

      {:ok, opts} = Request.validate(model, [])
      assert opts[:max_tokens] == 4096
    end
  end

  describe "build/3" do
    test "returns {:ok, %Req.Request{}} with correct URL and body" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1"
        })

      assert %Req.Request{} = req
      assert URI.to_string(req.url) == "https://api.test.com/v1/dummy"
      assert req.options.json["model"] == "test-model"
    end

    test "applies merged headers" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1",
          headers: %{"x-custom" => "from-config", "x-extra" => "from-call"}
        })

      assert Req.Request.get_header(req, "x-custom") == ["from-config"]
      assert Req.Request.get_header(req, "x-extra") == ["from-call"]
    end

    test "applies authentication" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1"
        })

      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test"]
    end

    test "modify_body is applied to dialect output" do
      model = make_model(provider(module: AugmentingModule))
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1"
        })

      assert req.options.json["modified"] == "test-model"
    end

    test "plug is merged when present" do
      model = make_model()
      context = Omni.Context.new("Hello")
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1",
          plug: plug
        })

      assert req.options[:plug] == plug
    end

    test "error propagation from authenticate" do
      model = make_model()
      context = Omni.Context.new("Hello")

      assert {:error, :no_api_key} =
               Request.build(model, context, %{
                 api_key: nil,
                 base_url: "https://api.test.com/v1"
               })
    end

    test "sets into: :self for streaming" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1"
        })

      assert req.into == :self
    end

    test "accepts keyword opts and validates internally" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} = Request.build(model, context, api_key: "sk-test")

      assert %Req.Request{} = req
      assert URI.to_string(req.url) == "https://api.test.com/v1/dummy"
      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test"]
    end

    test "default timeout applies as receive_timeout on Req request" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1"
        })

      assert req.options[:receive_timeout] == 300_000
    end

    test "custom timeout applies as receive_timeout on Req request" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
          base_url: "https://api.test.com/v1",
          timeout: 60_000
        })

      assert req.options[:receive_timeout] == 60_000
    end
  end

  describe "build/3 — auth" do
    defp sent_auth(provider_attrs, dialect \\ DummyDialect) do
      model = make_model(provider(provider_attrs), dialect)
      {:ok, req} = Request.build(model, Omni.Context.new("Hello"), api_key: "sk-test")
      Map.take(req.headers, ["authorization", "x-api-key", "x-key"])
    end

    test ":bearer sends an Authorization Bearer header" do
      assert sent_auth(auth: :bearer) == %{"authorization" => ["Bearer sk-test"]}
    end

    test "{:header, name} sends the raw key on that header" do
      assert sent_auth(auth: {:header, "x-key"}) == %{"x-key" => ["sk-test"]}
    end

    test ":none sends no credentials, even with a key" do
      assert sent_auth(auth: :none) == %{}
    end

    test ":dialect uses the dialect's scheme" do
      assert sent_auth([auth: :dialect], DummyDialect) == %{
               "authorization" => ["Bearer sk-test"]
             }

      assert sent_auth([auth: :dialect], HeaderAuthDialect) == %{"x-api-key" => ["sk-test"]}
    end

    test "unset auth behaves as :dialect" do
      assert sent_auth([auth: nil], HeaderAuthDialect) == %{"x-api-key" => ["sk-test"]}
    end

    test "a missing key is an error unless auth is :none" do
      model = make_model(provider(api_key: nil))
      assert {:error, :no_api_key} = Request.build(model, Omni.Context.new("Hello"), [])

      model = make_model(provider(api_key: nil, auth: :none))
      assert {:ok, _req} = Request.build(model, Omni.Context.new("Hello"), [])
    end

    test "modify_request runs after auth" do
      model = make_model(provider(module: AugmentingModule))

      {:ok, req} = Request.build(model, Omni.Context.new("Hello"), api_key: "sk-test")

      assert Req.Request.get_header(req, "x-provider") == ["request_test"]
      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test"]
    end
  end

  describe "validate_context/2" do
    test "text/* always passes even with text-only model" do
      model = make_model() |> Map.put(:input_modalities, [:text])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(source: {:base64, "data"}, media_type: "text/plain")
            ]
          )
        ])

      assert :ok = Request.validate_context(model, context)
    end

    test "application/json treated as text, always passes" do
      model = make_model() |> Map.put(:input_modalities, [:text])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(
                source: {:base64, "data"},
                media_type: "application/json"
              )
            ]
          )
        ])

      assert :ok = Request.validate_context(model, context)
    end

    test "image/* passes with :image modality" do
      model = make_model() |> Map.put(:input_modalities, [:text, :image])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(source: {:base64, "data"}, media_type: "image/png")
            ]
          )
        ])

      assert :ok = Request.validate_context(model, context)
    end

    test "image/* rejected without :image modality" do
      model = make_model() |> Map.put(:input_modalities, [:text])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(source: {:base64, "data"}, media_type: "image/png")
            ]
          )
        ])

      assert {:error, {:unsupported_modality, :image}} =
               Request.validate_context(model, context)
    end

    test "application/pdf passes with :pdf modality" do
      model = make_model() |> Map.put(:input_modalities, [:text, :pdf])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(
                source: {:base64, "data"},
                media_type: "application/pdf"
              )
            ]
          )
        ])

      assert :ok = Request.validate_context(model, context)
    end

    test "application/pdf rejected without :pdf modality" do
      model = make_model() |> Map.put(:input_modalities, [:text])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(
                source: {:base64, "data"},
                media_type: "application/pdf"
              )
            ]
          )
        ])

      assert {:error, {:unsupported_modality, :pdf}} =
               Request.validate_context(model, context)
    end

    test "audio/* rejected (no model has :audio)" do
      model = make_model() |> Map.put(:input_modalities, [:text, :image, :pdf])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(source: {:base64, "data"}, media_type: "audio/mp3")
            ]
          )
        ])

      assert {:error, {:unsupported_modality, :audio}} =
               Request.validate_context(model, context)
    end

    test "unknown media type rejected" do
      model = make_model() |> Map.put(:input_modalities, [:text, :image, :pdf])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [
              Omni.Content.Attachment.new(
                source: {:base64, "data"},
                media_type: "application/octet-stream"
              )
            ]
          )
        ])

      assert {:error, {:unsupported_media_type, "application/octet-stream"}} =
               Request.validate_context(model, context)
    end

    test "non-attachment content blocks ignored" do
      model = make_model() |> Map.put(:input_modalities, [:text])

      context =
        Omni.Context.new([
          Omni.Message.new(
            role: :user,
            content: [Omni.Content.Text.new("Hello"), Omni.Content.Text.new("World")]
          )
        ])

      assert :ok = Request.validate_context(model, context)
    end

    test "empty context passes" do
      model = make_model() |> Map.put(:input_modalities, [:text])
      context = Omni.Context.new(messages: [])

      assert :ok = Request.validate_context(model, context)
    end
  end

  describe "stream/3" do
    test "selects SSE parser for text/event-stream content-type" do
      Req.Test.stub(:stream_sse, fn conn ->
        body = File.read!("test/support/fixtures/synthetic/anthropic_truncated.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      model = make_model()

      {:ok, req} =
        Request.build(model, Omni.Context.new("Hello"),
          api_key: "test-key",
          plug: {Req.Test, :stream_sse}
        )

      assert {:ok, %Omni.StreamingResponse{}} = Request.stream(req, model, [])
    end

    test "selects NDJSON parser for application/x-ndjson content-type" do
      Req.Test.stub(:stream_ndjson, fn conn ->
        body =
          ~s({"message":{"role":"assistant","content":"Hi"},"done":true,"done_reason":"stop"}\n)

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, body)
      end)

      model = make_model(@provider, Omni.Dialects.OllamaChat)

      {:ok, req} =
        Request.build(model, Omni.Context.new("Hello"),
          api_key: "test-key",
          plug: {Req.Test, :stream_ndjson}
        )

      assert {:ok, %Omni.StreamingResponse{}} = Request.stream(req, model, [])
    end

    test "non-200 status returns HTTP error with parsed body" do
      Req.Test.stub(:stream_401, fn conn ->
        body = JSON.encode!(%{"error" => %{"message" => "Unauthorized"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, body)
      end)

      model = make_model()

      {:ok, req} =
        Request.build(model, Omni.Context.new("Hello"),
          api_key: "test-key",
          plug: {Req.Test, :stream_401}
        )

      assert {:error, {:http_error, 401, %{"error" => _}}} = Request.stream(req, model, [])
    end
  end

  describe "parse_event/2" do
    test "pipes through dialect handle_event" do
      model = make_model()
      event = %{"type" => "message_start"}

      assert [{:message, %{model: "test"}}] = Request.parse_event(model, event)
    end

    test "returns empty list for skippable events" do
      model = make_model()
      event = %{"type" => "ping"}

      assert [] == Request.parse_event(model, event)
    end

    test "passes the model to the dialect" do
      model = make_model(provider(module: AugmentingModule))

      assert [{:message, %{model: "test"}}] =
               Request.parse_event(model, %{"type" => "message_start"})
    end
  end
end
