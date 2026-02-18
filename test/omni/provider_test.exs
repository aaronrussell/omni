defmodule Omni.ProviderTest do
  use ExUnit.Case, async: true

  alias Omni.Provider

  defmodule DummyDialect do
    @moduledoc false
  end

  defmodule TestProvider do
    use Omni.Provider, dialect: Omni.ProviderTest.DummyDialect

    @impl true
    def config, do: %{base_url: "https://api.test.com", auth_header: "authorization"}
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

  describe "stream/4" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} =
               Provider.stream(TestProvider, "/v1/messages", %{}, [])
    end
  end
end
