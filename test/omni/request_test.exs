defmodule Omni.RequestTest do
  use ExUnit.Case, async: true

  alias Omni.Request
  alias Omni.Provider.Endpoint

  defmodule DummyDialect do
    @moduledoc false
    use Omni.Dialect, :text

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
    use Omni.Dialect, :text

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

  defmodule EchoDialect do
    @moduledoc false
    use Omni.Dialect, :text

    @impl true
    def option_schema, do: %{}

    @impl true
    def compat_schema, do: %{}

    @impl true
    def auth, do: :bearer

    @impl true
    def handle_path(_model, _opts), do: "/echo"

    # Hands back the messages, so tests see what a dialect is given.
    @impl true
    def handle_body(_model, context, _opts), do: %{"messages" => context.messages}

    @impl true
    def handle_event(_event, _model), do: []
  end

  @provider %Omni.Provider{
    id: :request_test,
    api_key: {:system, "TEST_PROVIDER_KEY"},
    auth: :dialect,
    headers: %{"x-custom" => "from-config"},
    dialects: %{DummyDialect => %Endpoint{base_url: "https://api.test.com/v1"}}
  }

  defp provider(attrs), do: struct!(@provider, attrs)

  # The provider gets an endpoint for the model's dialect if it has none.
  defp make_model(provider \\ @provider, dialect \\ DummyDialect) do
    endpoint = %Endpoint{base_url: "https://api.test.com/v1"}
    provider = %{provider | dialects: Map.put_new(provider.dialects, dialect, endpoint)}

    Omni.Model.new(
      id: "test-model",
      name: "Test Model",
      provider: provider,
      dialects: %{text: dialect},
      max_output_tokens: 2048
    )
  end

  defp endpoint_model(base_url) do
    make_model(provider(dialects: %{DummyDialect => %Endpoint{base_url: base_url}}))
  end

  describe "validate/3" do
    test "merges provider values with call-site opts" do
      model = make_model()

      {:ok, opts} =
        Request.validate(model, :text, api_key: "sk-test", max_tokens: 1024, temperature: 0.7)

      assert opts.api_key == "sk-test"
      assert opts[:max_tokens] == 1024
      assert opts[:temperature] == 0.7
    end

    test "api_key: call-site wins" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, api_key: "from-call")
      assert opts.api_key == "from-call"
    end

    test "api_key: provider value otherwise" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, [])
      assert opts.api_key == {:system, "TEST_PROVIDER_KEY"}
    end

    test "provider struct fields other than api_key and headers are not options" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, [])
      refute Map.has_key?(opts, :dialects)
      refute Map.has_key?(opts, :auth)
      refute Map.has_key?(opts, :host)
    end

    test "base_url is no longer an option" do
      assert {:error, {:unknown_options, [:base_url]}} =
               Request.validate(make_model(), :text, base_url: "https://custom.api.com")
    end

    test "plug extraction" do
      model = make_model()
      plug = {Plug.Test, []}

      {:ok, opts} = Request.validate(model, :text, plug: plug)
      assert opts.plug == plug
    end

    test "timeout defaults to 300_000" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, [])
      assert opts.timeout == 300_000
    end

    test "inference opts pass through" do
      model = make_model()

      {:ok, opts} =
        Request.validate(model, :text, max_tokens: 2048, thinking: :high, cache: :short)

      assert opts[:max_tokens] == 2048
      assert opts[:thinking] == :high
      assert opts[:cache] == :short
    end

    test "headers merge additively: provider then call-site" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, headers: %{"x-call" => "from-call"})

      assert opts.headers["x-custom"] == "from-config"
      assert opts.headers["x-call"] == "from-call"
    end

    test "unknown keys rejected" do
      model = make_model()

      assert {:error, {:unknown_options, [:temperture]}} =
               Request.validate(model, :text, temperture: 0.7)
    end

    test "max_tokens optional (nil when not provided)" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, [])
      assert opts[:max_tokens] == nil
    end

    test "temperature accepts integer" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, temperature: 0)
      assert opts[:temperature] == 0
    end

    test "temperature accepts float" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, temperature: 0.5)
      assert opts[:temperature] == 0.5
    end

    test "thinking accepts true" do
      model = make_model()

      assert {:ok, %{thinking: true}} = Request.validate(model, :text, thinking: true)
    end

    test "thinking rejects :none" do
      model = make_model()

      assert {:error, _} = Request.validate(model, :text, thinking: :none)
    end

    test "thinking accepts boolean false" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, thinking: false)
      assert opts[:thinking] == false
    end

    test "thinking accepts effort atom" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, thinking: :high)
      assert opts[:thinking] == :high
    end

    test "thinking accepts :xhigh effort" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, thinking: :xhigh)
      assert opts[:thinking] == :xhigh
    end

    test "thinking accepts keyword list (converted to map by Peri)" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, thinking: [effort: :high, budget: 10000])
      assert opts[:thinking].effort == :high
      assert opts[:thinking].budget == 10000
    end

    test "thinking rejects invalid value" do
      model = make_model()

      assert {:error, _} = Request.validate(model, :text, thinking: "invalid")
    end

    test "cache accepts :short" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, cache: :short)
      assert opts[:cache] == :short
    end

    test "cache accepts :long" do
      model = make_model()

      {:ok, opts} = Request.validate(model, :text, cache: :long)
      assert opts[:cache] == :long
    end

    test "cache rejects invalid value" do
      model = make_model()

      assert {:error, _} = Request.validate(model, :text, cache: :invalid)
    end

    test "max_tokens rejects non-integer" do
      model = make_model()

      assert {:error, _} = Request.validate(model, :text, max_tokens: "big")
    end

    test "output accepts map" do
      model = make_model()
      schema = %{type: :object, properties: %{name: %{type: :string}}}

      {:ok, opts} = Request.validate(model, :text, output: schema)
      assert opts[:output] == schema
    end

    test "output rejects non-map" do
      model = make_model()

      assert {:error, _} = Request.validate(model, :text, output: "not a map")
    end

    test "dialect option_schema merge overrides universal schema" do
      # Create a dialect that overrides max_tokens with a default
      defmodule OverrideDialect do
        @moduledoc false
        use Omni.Dialect, :text

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

      {:ok, opts} = Request.validate(model, :text, [])
      assert opts[:max_tokens] == 4096
    end
  end

  describe "build/3 replay of other models' turns" do
    alias Omni.{Context, Message}
    alias Omni.Content.{Text, Thinking, ToolUse}

    defp assistant(origin, content \\ nil) do
      Message.new(
        role: :assistant,
        origin: origin,
        private: %{reasoning_details: [%{"type" => "reasoning.text"}]},
        content:
          content ||
            [
              Thinking.new(text: "Hmm", signature: "sig"),
              Text.new(text: "Checking", signature: "text_sig"),
              ToolUse.new(id: "t1", name: "lookup", input: %{}, signature: "use_sig")
            ]
      )
    end

    defp sent(messages) do
      model = make_model(@provider, EchoDialect)
      {:ok, req} = Request.build(model, Context.new(messages), %{api_key: "sk-test"})
      req.options.json["messages"]
    end

    defp stripped?(%Message{content: content, private: private}) do
      private == %{} and
        content == [
          Text.new(text: "Checking"),
          ToolUse.new(id: "t1", name: "lookup", input: %{})
        ]
    end

    test "sends everything back to the same provider and dialect, whatever the model" do
      messages = [
        Message.new("Hi"),
        assistant(%{model: {:request_test, "other-model"}, dialect: EchoDialect})
      ]

      assert sent(messages) == messages
    end

    test "drops thinking, signatures and private from another provider" do
      [_, message] =
        sent([Message.new("Hi"), assistant(%{model: {:other, "m"}, dialect: EchoDialect})])

      assert stripped?(message)
    end

    test "drops them from the same provider on another dialect" do
      origin = %{model: {:request_test, "test-model"}, dialect: DummyDialect}
      [_, message] = sent([Message.new("Hi"), assistant(origin)])
      assert stripped?(message)
    end

    test "drops them from a message with no origin" do
      [_, message] = sent([Message.new("Hi"), assistant(nil)])
      assert stripped?(message)
    end

    test "drops a foreign message that held only thinking" do
      only_thinking = assistant(nil, [Thinking.new(text: "Hmm", signature: "sig")])

      assert [%Message{role: :user}, %Message{role: :user}] =
               sent([Message.new("Hi"), only_thinking, Message.new("Again")])
    end
  end

  describe "build/3" do
    test "returns {:ok, %Req.Request{}} with correct URL and body" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test"
        })

      assert %Req.Request{} = req
      assert URI.to_string(req.url) == "https://api.test.com/v1/dummy"
      assert req.options.json["model"] == "test-model"
    end

    test "joins a base URL with a trailing slash without doubling it" do
      {:ok, req} =
        Request.build(endpoint_model("https://api.test.com/v1/"), Omni.Context.new("Hello"),
          api_key: "sk-test"
        )

      assert URI.to_string(req.url) == "https://api.test.com/v1/dummy"
    end

    test "host: replaces the origin of the endpoint URL and keeps its path" do
      {:ok, req} =
        Request.build(make_model(), Omni.Context.new("Hello"),
          api_key: "sk-test",
          host: "http://localhost:4000"
        )

      assert URI.to_string(req.url) == "http://localhost:4000/v1/dummy"
    end

    test "host: fills a templated origin" do
      model = endpoint_model("${GATEWAY_BASE_URL}/openai/v1")

      {:ok, req} =
        Request.build(model, Omni.Context.new("Hello"),
          api_key: "sk-test",
          host: "https://gw.example.com"
        )

      assert URI.to_string(req.url) == "https://gw.example.com/openai/v1/dummy"
    end

    test "host: with a path is an error" do
      assert {:error, {:invalid_host, "http://localhost:4000/v1"}} =
               Request.build(make_model(), Omni.Context.new("Hello"),
                 api_key: "sk-test",
                 host: "http://localhost:4000/v1"
               )
    end

    test "a model whose dialect has no endpoint is an error" do
      model = %{make_model() | provider: provider(dialects: %{})}

      assert {:error, {:no_endpoint, DummyDialect}} =
               Request.build(model, Omni.Context.new("Hello"), api_key: "sk-test")
    end

    test "an endpoint with no URL is an error" do
      assert {:error, {:no_base_url, DummyDialect}} =
               Request.build(endpoint_model(nil), Omni.Context.new("Hello"), api_key: "sk-test")
    end

    test "an endpoint URL still holding a placeholder is an error" do
      model = endpoint_model("https://{region}.api.test.com/v1")

      assert {:error, {:no_base_url, DummyDialect}} =
               Request.build(model, Omni.Context.new("Hello"), api_key: "sk-test")
    end

    test "a model with no text dialect is an error" do
      model = %{make_model() | dialects: %{}}

      assert {:error, {:unsupported_capability, :text}} =
               Request.build(model, Omni.Context.new("Hello"), api_key: "sk-test")
    end

    test "applies merged headers" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
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
          api_key: "sk-test"
        })

      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test"]
    end

    test "modify_body is applied to dialect output" do
      model = make_model(provider(module: AugmentingModule))
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test"
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
          plug: plug
        })

      assert req.options[:plug] == plug
    end

    test "error propagation from authenticate" do
      model = make_model()
      context = Omni.Context.new("Hello")

      assert {:error, :no_api_key} =
               Request.build(model, context, %{
                 api_key: nil
               })
    end

    test "sets into: :self for streaming" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test"
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
          api_key: "sk-test"
        })

      assert req.options[:receive_timeout] == 300_000
    end

    test "custom timeout applies as receive_timeout on Req request" do
      model = make_model()
      context = Omni.Context.new("Hello")

      {:ok, req} =
        Request.build(model, context, %{
          api_key: "sk-test",
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

  describe "decisions" do
    alias Omni.{Answer, Decision, Usage}

    @decision_provider %Omni.Provider{
      id: :decision_test,
      api_key: "sk-test",
      auth: :dialect,
      headers: %{},
      dialects: %{
        Omni.Dialects.SystemOne => %Endpoint{base_url: "https://api.typesafe.test/v1"},
        Omni.Dialects.OpenAIDecisions => %Endpoint{base_url: "https://api.openai.test/v1"}
      }
    }

    defp decision_model(dialect \\ Omni.Dialects.SystemOne, provider \\ @decision_provider) do
      Omni.Model.new(
        id: "jev-1.14",
        name: "Jev",
        provider: provider,
        dialects: %{decision: dialect},
        input_cost: 0.042
      )
    end

    defp spam_decision,
      do: Decision.new({"Buy cheap watches!", [spam: Omni.predicate("Is this spam?")]})

    test "build/3 posts JSON to the decision endpoint, not streamed, with auth" do
      assert {:ok, req} = Request.build(decision_model(), spam_decision(), [])

      assert URI.to_string(req.url) == "https://api.typesafe.test/v1/systemone"
      assert req.method == :post
      assert req.into == nil
      assert Req.Request.get_header(req, "authorization") == ["Bearer sk-test"]

      assert req.options[:json]["questions"] == %{
               "spam" => %{"type" => "noul", "instructions" => "Is this spam?"}
             }
    end

    test "build/3 moves the origin with a call-site host:" do
      assert {:ok, req} =
               Request.build(decision_model(), spam_decision(), host: "http://localhost:4000")

      assert URI.to_string(req.url) == "http://localhost:4000/v1/systemone"
    end

    test "build/3 takes the dialect's options and rejects text options" do
      model = decision_model(Omni.Dialects.OpenAIDecisions)

      assert {:ok, req} = Request.build(model, spam_decision(), safety_identifier: "user-1")
      assert req.options[:json]["safety_identifier"] == "user-1"

      assert {:error, {:unknown_options, [:max_tokens]}} =
               Request.build(model, spam_decision(), max_tokens: 100)
    end

    test "build/3 validates the decision before any request" do
      bad = Decision.new({"x", [team: Omni.choice("Which?", [:one])]})
      assert {:error, [%Peri.Error{message: message}]} = Request.build(decision_model(), bad, [])
      assert message =~ "at least two choices"
    end

    test "build/3 needs a decision dialect and an endpoint for it" do
      text_model = make_model()

      assert Request.build(text_model, spam_decision(), []) ==
               {:error, {:unsupported_capability, :decision}}

      assert Request.build(decision_model(), Omni.Context.new("Hi"), []) ==
               {:error, {:unsupported_capability, :text}}

      no_endpoint = decision_model(Omni.Dialects.SystemOne, %{@decision_provider | dialects: %{}})

      assert Request.build(no_endpoint, spam_decision(), []) ==
               {:error, {:no_endpoint, Omni.Dialects.SystemOne}}
    end

    test "build/3 passes the decision to the provider module's modify_body/4" do
      defmodule DecisionHook do
        @behaviour Omni.Provider

        @impl true
        def modify_body(body, _model, %Decision{questions: questions}, _opts),
          do: Map.put(body, "count", length(questions))
      end

      model =
        decision_model(Omni.Dialects.SystemOne, %{@decision_provider | module: DecisionHook})

      assert {:ok, req} = Request.build(model, spam_decision(), [])
      assert req.options[:json]["count"] == 1
    end

    defp send_decision(stub, opts \\ []) do
      model = decision_model()
      decision = spam_decision()
      {:ok, req} = Request.build(model, decision, plug: {Req.Test, stub})
      Request.send(req, model, decision, opts)
    end

    test "send/4 decodes the answer and prices the usage" do
      Req.Test.stub(:decision_ok, fn conn ->
        Req.Test.json(conn, %{
          "answers" => %{"spam" => %{"type" => "noul", "noul" => 0.98}},
          "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 1}
        })
      end)

      assert {:ok, %Decision{} = decision} = send_decision(:decision_ok)
      assert decision.answers == [spam: %Answer.Predicate{probability: 0.98}]

      assert %Usage{input_tokens: 1_000_000, input_cost: 0.042, total_tokens: 1_000_001} =
               decision.usage

      assert decision.model.id == "jev-1.14"
      assert decision.raw == nil
    end

    test "send/4 decodes a JSON body Req left as text, and attaches raw on request" do
      Req.Test.stub(:decision_text, fn conn ->
        body = JSON.encode!(%{"answers" => %{"spam" => %{"type" => "noul", "noul" => 0.5}}})
        Plug.Conn.send_resp(conn, 200, body)
      end)

      assert {:ok, %Decision{raw: {%Req.Request{}, %Req.Response{}}} = decision} =
               send_decision(:decision_text, raw: true)

      assert decision.answers == [spam: %Answer.Predicate{probability: 0.5}]
      assert decision.usage.total_tokens == 0
    end

    test "send/4 returns HTTP errors with the parsed body" do
      Req.Test.stub(:decision_422, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"detail" => [%{"msg" => "Field required"}]})
      end)

      assert {:error, {:http_error, 422, %{"detail" => _}}} = send_decision(:decision_422)
    end

    test "send/4 rejects a body that isn't a JSON object" do
      Req.Test.stub(:decision_html, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
      assert {:error, {:invalid_response, "<html>"}} = send_decision(:decision_html)
    end
  end
end
