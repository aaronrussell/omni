defmodule Omni.ProviderTest do
  use ExUnit.Case, async: true

  alias Omni.Provider

  defmodule DummyDialect do
    @moduledoc false
    @behaviour Omni.Dialect

    @impl true
    def option_schema, do: %{}

    @impl true
    def handle_path(_model, _opts), do: "/v1/dummy"

    @impl true
    def handle_body(model, _context, opts) do
      %{"model" => model.id, "max_tokens" => opts[:max_tokens] || 1024}
    end

    @impl true
    def handle_event(%{"type" => "message_start"}), do: [{:start, %{}}]
    def handle_event(_), do: []
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

    test "models/0 returns empty list by default" do
      assert TestProvider.models() == []
    end

    test "build_url/2 concatenates base URL from opts and path" do
      assert TestProvider.build_url("/v1/chat", %{base_url: "https://api.example.com"}) ==
               "https://api.example.com/v1/chat"
    end

    test "modify_body/3 passes through body unchanged" do
      body = %{"model" => "test", "messages" => []}
      assert TestProvider.modify_body(body, %Omni.Context{}, %{}) == body
    end

    test "modify_events/2 passes through deltas unchanged" do
      deltas = [{:block_delta, %{type: :text, index: 0, delta: "hi"}}]
      assert TestProvider.modify_events(deltas, %{"type" => "chunk"}) == deltas
    end

    test "authenticate/2 adds literal API key as authorization header" do
      req = Req.new()

      assert {:ok, authed_req} =
               TestProvider.authenticate(req, %{
                 api_key: "sk-test-123",
                 auth_header: "authorization"
               })

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

  describe "load/1" do
    setup do
      on_exit(fn ->
        try do
          :persistent_term.erase({Omni, :test_load})
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "loads models into persistent_term for a builtin provider atom" do
      Provider.load([:openai])

      models = :persistent_term.get({Omni, :openai})
      assert is_map(models)
      assert map_size(models) > 0
      assert %Omni.Model{} = models |> Map.values() |> hd()
    end

    test "loads models for a {id, module} custom provider" do
      Provider.load(test_load: TestProvider)

      models = :persistent_term.get({Omni, :test_load})
      assert models == %{}
    end

    test "merges with existing entries" do
      :persistent_term.put({Omni, :test_load}, %{"existing" => :kept})

      Provider.load(test_load: TestProvider)

      models = :persistent_term.get({Omni, :test_load})
      assert models["existing"] == :kept
    end

    test "raises on unknown atom" do
      assert_raise ArgumentError, ~r/unknown built-in provider/, fn ->
        Provider.load([:nonexistent_provider])
      end
    end
  end
end
