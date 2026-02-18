defmodule Omni.ProviderTest do
  use ExUnit.Case, async: true

  alias Omni.Provider

  defmodule DummyDialect do
    @moduledoc false
    @behaviour Omni.Dialect

    @impl true
    def option_schema, do: %{}

    @impl true
    def build_path(_model), do: "/v1/dummy"

    @impl true
    def build_body(model, _context, opts) do
      {:ok, %{"model" => model.id, "max_tokens" => Keyword.get(opts, :max_tokens, 1024)}}
    end

    @impl true
    def parse_event(%{"type" => "message_start"}), do: {:start, %{}}
    def parse_event(_), do: nil
  end

  defmodule TestProvider do
    use Omni.Provider, dialect: Omni.ProviderTest.DummyDialect

    @impl true
    def config do
      %{
        base_url: "https://api.test.com",
        auth_header: "authorization",
        api_key: {:system, "TEST_PROVIDER_KEY"},
        headers: %{"x-custom" => "from-config"}
      }
    end
  end

  @fixture_path Path.expand("../support/fixtures/test_models.json", __DIR__)

  describe "__using__/1 macro" do
    test "dialect/0 returns the configured dialect module" do
      assert TestProvider.dialect() == DummyDialect
    end

    test "option_schema/0 returns empty map by default" do
      assert TestProvider.option_schema() == %{}
    end

    test "models/0 returns empty list by default" do
      assert TestProvider.models() == []
    end

    test "build_url/2 concatenates base URL and path" do
      assert TestProvider.build_url("https://api.example.com", "/v1/chat") ==
               "https://api.example.com/v1/chat"
    end

    test "adapt_body/2 passes through body unchanged" do
      body = %{"model" => "test", "messages" => []}
      assert TestProvider.adapt_body(body, []) == body
    end

    test "adapt_event/1 passes through event unchanged" do
      event = %{"type" => "content_block_delta", "delta" => %{"text" => "hi"}}
      assert TestProvider.adapt_event(event) == event
    end

    test "authenticate/2 adds literal API key as authorization header" do
      req = Req.new()
      assert {:ok, authed_req} = TestProvider.authenticate(req, api_key: "sk-test-123")
      assert Req.Request.get_header(authed_req, "authorization") == ["sk-test-123"]
    end
  end

  describe "resolve_auth/1" do
    test "returns literal string as-is" do
      assert {:ok, "sk-test-key"} = Provider.resolve_auth("sk-test-key")
    end

    test "resolves {:system, env_var} from environment" do
      System.put_env("OMNI_TEST_API_KEY", "from-env")
      assert {:ok, "from-env"} = Provider.resolve_auth({:system, "OMNI_TEST_API_KEY"})
    after
      System.delete_env("OMNI_TEST_API_KEY")
    end

    test "returns error when {:system, env_var} is not set" do
      System.delete_env("OMNI_MISSING_KEY")

      assert {:error, {:missing_env_var, "OMNI_MISSING_KEY"}} =
               Provider.resolve_auth({:system, "OMNI_MISSING_KEY"})
    end

    test "resolves MFA tuple via apply" do
      assert {:ok, "resolved"} =
               Provider.resolve_auth({String, :trim, ["  resolved  "]})
    end

    test "returns error when MFA raises" do
      assert {:error, %ArgumentError{}} =
               Provider.resolve_auth({String, :to_integer, ["not_a_number"]})
    end

    test "returns {:error, :no_api_key} for nil" do
      assert {:error, :no_api_key} = Provider.resolve_auth(nil)
    end
  end

  describe "load_models/2" do
    test "loads correct number of models from fixture" do
      models = Provider.load_models(TestProvider, @fixture_path)
      assert length(models) == 3
    end

    test "stamps provider and dialect on every model" do
      models = Provider.load_models(TestProvider, @fixture_path)

      for model <- models do
        assert model.provider == TestProvider
        assert model.dialect == DummyDialect
      end
    end

    test "maps all JSON fields to struct fields" do
      [small | _] = Provider.load_models(TestProvider, @fixture_path)

      assert %Omni.Model{
               id: "test-model-small",
               name: "Test Model Small",
               context_size: 8192,
               max_output_tokens: 2048,
               input_cost: 0.5,
               output_cost: 1.5,
               cache_read_cost: 0.05,
               cache_write_cost: 0.5
             } = small
    end

    test "converts modality strings to atoms and filters to supported" do
      models = Provider.load_models(TestProvider, @fixture_path)
      multi = Enum.find(models, &(&1.id == "test-model-multi"))

      assert multi.input_modalities == [:text, :image]
      assert multi.output_modalities == [:text]
    end

    test "loads reasoning flag correctly" do
      models = Provider.load_models(TestProvider, @fixture_path)
      small = Enum.find(models, &(&1.id == "test-model-small"))
      large = Enum.find(models, &(&1.id == "test-model-large"))

      refute small.reasoning
      assert large.reasoning
    end
  end

  describe "new_request/4" do
    test "returns {:ok, %Req.Request{}} with correct URL, method, and body" do
      {:ok, req} =
        Provider.new_request(TestProvider, "/v1/chat", %{"model" => "test"}, api_key: "sk-test")

      assert req.method == :post
      assert URI.to_string(req.url) == "https://api.test.com/v1/chat"
      assert req.options.json == %{"model" => "test"}
    end

    test "applies config headers" do
      {:ok, req} =
        Provider.new_request(TestProvider, "/v1/chat", %{}, api_key: "sk-test")

      assert Req.Request.get_header(req, "x-custom") == ["from-config"]
    end

    test "applies authentication header" do
      {:ok, req} =
        Provider.new_request(TestProvider, "/v1/chat", %{}, api_key: "sk-test")

      assert Req.Request.get_header(req, "authorization") == ["sk-test"]
    end

    test "base_url override via opts" do
      {:ok, req} =
        Provider.new_request(TestProvider, "/v1/chat", %{},
          api_key: "sk-test",
          base_url: "https://custom.api.com"
        )

      assert URI.to_string(req.url) == "https://custom.api.com/v1/chat"
    end

    test "api_key falls back to provider config default" do
      System.put_env("TEST_PROVIDER_KEY", "from-env")

      {:ok, req} = Provider.new_request(TestProvider, "/v1/chat", %{})

      assert Req.Request.get_header(req, "authorization") == ["from-env"]
    after
      System.delete_env("TEST_PROVIDER_KEY")
    end

    test "api_key falls back to app config before provider config" do
      Application.put_env(:omni, TestProvider, api_key: "from-app-config")

      {:ok, req} = Provider.new_request(TestProvider, "/v1/chat", %{})

      assert Req.Request.get_header(req, "authorization") == ["from-app-config"]
    after
      Application.delete_env(:omni, TestProvider)
    end

    test "error propagation from authenticate/2 when api_key is missing" do
      System.delete_env("TEST_PROVIDER_KEY")

      assert {:error, {:missing_env_var, "TEST_PROVIDER_KEY"}} =
               Provider.new_request(TestProvider, "/v1/chat", %{})
    end

    test "sets into: :self for streaming" do
      {:ok, req} =
        Provider.new_request(TestProvider, "/v1/chat", %{}, api_key: "sk-test")

      assert req.into == :self
    end
  end

  describe "build_request/3" do
    setup do
      model =
        Omni.Model.new(
          id: "test-model",
          name: "Test Model",
          provider: TestProvider,
          dialect: DummyDialect,
          max_output_tokens: 2048
        )

      %{model: model}
    end

    test "returns {:ok, %Req.Request{}} with correct URL and body", %{model: model} do
      context = Omni.Context.new("Hello")

      {:ok, req} = Provider.build_request(model, context, api_key: "sk-test")

      assert %Req.Request{} = req
      assert URI.to_string(req.url) == "https://api.test.com/v1/dummy"
      assert req.options.json["model"] == "test-model"
    end

    test "build_body/3 error propagates", %{model: model} do
      defmodule FailDialect do
        @moduledoc false
        @behaviour Omni.Dialect

        def option_schema, do: %{}
        def build_path(_model), do: "/v1/fail"
        def build_body(_model, _context, _opts), do: {:error, :bad_body}
        def parse_event(_event), do: nil
      end

      model = %{model | dialect: FailDialect}
      context = Omni.Context.new("Hello")

      assert {:error, :bad_body} = Provider.build_request(model, context, api_key: "sk-test")
    end

    test "adapt_body/2 is applied to dialect output", %{model: model} do
      defmodule AdaptProvider do
        use Omni.Provider, dialect: Omni.ProviderTest.DummyDialect

        @impl true
        def config do
          %{
            base_url: "https://api.test.com",
            api_key: {:system, "TEST_PROVIDER_KEY"}
          }
        end

        @impl true
        def adapt_body(body, _opts) do
          Map.put(body, "adapted", true)
        end
      end

      model = %{model | provider: AdaptProvider}
      context = Omni.Context.new("Hello")

      {:ok, req} = Provider.build_request(model, context, api_key: "sk-test")

      assert req.options.json["adapted"] == true
    end
  end

  describe "parse_event/2" do
    test "pipes through adapt_event then dialect parse_event" do
      event = %{"type" => "message_start"}
      assert {:start, %{}} = Provider.parse_event(TestProvider, event)
    end

    test "returns nil for skippable events" do
      event = %{"type" => "ping"}
      assert nil == Provider.parse_event(TestProvider, event)
    end
  end
end
