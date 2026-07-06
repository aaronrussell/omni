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
    use Omni.Provider, id: :test_provider, dialect: Omni.ProviderTest.DummyDialect

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

  defmodule DuplicateIdProvider do
    use Omni.Provider, id: :test_provider

    @impl true
    def config, do: %{base_url: "https://dup.test"}
  end

  defmodule MultiDialectProvider do
    use Omni.Provider, id: :multi_dialect

    @impl true
    def config do
      %{
        base_url: "https://api.multi.test",
        api_key: {:system, "MULTI_TEST_KEY"}
      }
    end
  end

  @fixture_file Path.expand("../support/fixtures/test_models.json", __DIR__)
  @multi_dialect_fixture_file Path.expand(
                                "../support/fixtures/test_models_multi_dialect.json",
                                __DIR__
                              )

  describe "__using__/1 macro" do
    test "id/0 returns the declared canonical id" do
      assert TestProvider.id() == :test_provider
      assert MultiDialectProvider.id() == :multi_dialect
    end

    test "dialect/0 returns the configured dialect module" do
      assert TestProvider.dialect() == DummyDialect
    end

    test "dialect/0 returns nil when no dialect is declared" do
      assert MultiDialectProvider.dialect() == nil
    end

    test "models/0 defaults to loading from the model source under the module id" do
      # :test_provider is not a catalog entry — the default implementation
      # reaches the source, which warns and yields no models.
      {result, log} = ExUnit.CaptureLog.with_log(fn -> TestProvider.models() end)

      assert result == []
      assert log =~ "failed to load models for Omni.ProviderTest.TestProvider"
      assert log =~ ":unknown_provider"
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

    test "authenticate/2 adds Bearer authorization header by default" do
      req = Req.new()

      assert {:ok, authed_req} =
               TestProvider.authenticate(req, %{api_key: "sk-test-123"})

      assert Req.Request.get_header(authed_req, "authorization") == ["Bearer sk-test-123"]
    end

    test "authenticate/2 uses raw key with custom auth_header" do
      req = Req.new()

      assert {:ok, authed_req} =
               TestProvider.authenticate(req, %{
                 api_key: "sk-test-123",
                 auth_header: "x-api-key"
               })

      assert Req.Request.get_header(authed_req, "x-api-key") == ["sk-test-123"]
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

    test "returns error when MFA returns non-string" do
      assert {:error, {:invalid_auth_value, 12345}} =
               Provider.resolve_auth({String, :to_integer, ["12345"]})
    end

    test "returns {:error, :no_api_key} for nil" do
      assert {:error, :no_api_key} = Provider.resolve_auth(nil)
    end
  end

  describe "build_model/2" do
    defp fixture_entries(file) do
      file |> File.read!() |> JSON.decode!()
    end

    test "maps all data fields to struct fields" do
      [small | _] = fixture_entries(@fixture_file)

      assert %Omni.Model{
               id: "test-model-small",
               name: "Test Model Small",
               context_size: 8192,
               max_output_tokens: 2048,
               input_cost: 0.5,
               output_cost: 1.5,
               cache_read_cost: 0.05,
               cache_write_cost: 0.5,
               reasoning: false
             } = Provider.build_model(TestProvider, small)
    end

    test "stamps provider and falls back to the declared dialect" do
      for data <- fixture_entries(@fixture_file) do
        model = Provider.build_model(TestProvider, data)
        assert model.provider == TestProvider
        assert model.dialect == DummyDialect
      end
    end

    test "converts modality strings to atoms and filters to supported" do
      data = @fixture_file |> fixture_entries() |> Enum.find(&(&1["id"] == "test-model-multi"))
      model = Provider.build_model(TestProvider, data)

      assert model.input_modalities == [:text, :image]
      assert model.output_modalities == [:text]
    end

    test "defaults costs, limits, modalities, and reasoning when absent" do
      model = Provider.build_model(TestProvider, %{"id" => "bare", "name" => "Bare"})

      assert %Omni.Model{
               input_cost: 0,
               output_cost: 0,
               cache_read_cost: 0,
               cache_write_cost: 0,
               context_size: 0,
               max_output_tokens: 0,
               reasoning: false,
               input_modalities: [:text],
               output_modalities: [:text],
               release_date: nil
             } = model
    end

    test "parses full and year-month release dates" do
      full = Provider.build_model(TestProvider, %{"id" => "a", "release_date" => "2025-08-05"})
      month = Provider.build_model(TestProvider, %{"id" => "b", "release_date" => "2025-08"})

      assert full.release_date == ~D[2025-08-05]
      assert month.release_date == ~D[2025-08-01]
    end

    test "data dialect takes priority over the declared dialect" do
      for data <- fixture_entries(@multi_dialect_fixture_file) do
        model = Provider.build_model(TestProvider, data)
        refute model.dialect == DummyDialect
      end
    end

    test "resolves dialect from data when module declares none" do
      models =
        @multi_dialect_fixture_file
        |> fixture_entries()
        |> Map.new(&{&1["id"], Provider.build_model(MultiDialectProvider, &1)})

      assert models["claude-test"].dialect == Omni.Dialects.AnthropicMessages
      assert models["gpt-test"].dialect == Omni.Dialects.OpenAIResponses
      assert models["gemini-test"].dialect == Omni.Dialects.GoogleGemini
    end

    test "raises when neither data nor module supply a dialect" do
      assert_raise ArgumentError, ~r/no dialect specified/, fn ->
        Provider.build_model(MultiDialectProvider, %{"id" => "no-dialect"})
      end
    end

    test "raises on unknown dialect string" do
      assert_raise ArgumentError, ~r/unknown_dialect/, fn ->
        Provider.build_model(TestProvider, %{"id" => "bad", "dialect" => "bogus_format"})
      end
    end
  end

  describe "load_models/2 deprecation" do
    test "raises with a migration message on a file path argument" do
      assert_raise ArgumentError, ~r/no longer accepts a file path/, fn ->
        Provider.load_models(TestProvider, "priv/models/test.json")
      end
    end
  end

  describe "providers_from_config/1" do
    test "nil loads all built-in providers" do
      assert Provider.providers_from_config(nil) == Provider.builtins()
    end

    test "providers: defaults to :all" do
      assert Provider.providers_from_config(source: Omni.Sources.ModelsDev) ==
               Provider.builtins()

      assert Provider.providers_from_config([]) == Provider.builtins()
    end

    test "providers: :all expands to all built-in providers" do
      assert Provider.providers_from_config(providers: :all) == Provider.builtins()
    end

    test "providers: passes a module list through" do
      assert Provider.providers_from_config(providers: [Omni.Providers.Anthropic, TestProvider]) ==
               [Omni.Providers.Anthropic, TestProvider]
    end

    test "providers: expands :all inside the list" do
      assert Provider.providers_from_config(providers: [:all, TestProvider]) ==
               Provider.builtins() ++ [TestProvider]
    end

    test "raises on bare provider-id atoms" do
      assert_raise ArgumentError, ~r/no longer accepted/, fn ->
        Provider.providers_from_config(providers: [:anthropic, :openai])
      end
    end

    test "raises on {id, module} pairs" do
      assert_raise ArgumentError, ~r/no longer accepted/, fn ->
        Provider.providers_from_config(providers: [acme: TestProvider])
      end
    end

    test "raises on an invalid providers: value" do
      assert_raise ArgumentError, ~r/invalid providers: value/, fn ->
        Provider.providers_from_config(providers: :anthropic)
      end
    end

    test "raises with a migration message on the legacy list shape" do
      assert_raise ArgumentError, ~r/moved from :providers to :models/, fn ->
        Provider.providers_from_config([:anthropic, :openai])
      end

      assert_raise ArgumentError, ~r/moved from :providers to :models/, fn ->
        Provider.providers_from_config([:anthropic, acme: TestProvider])
      end

      assert_raise ArgumentError, ~r/moved from :providers to :models/, fn ->
        Provider.providers_from_config(acme: TestProvider)
      end
    end

    test "raises with a migration message on a non-list value" do
      assert_raise ArgumentError, ~r/moved from :providers to :models/, fn ->
        Provider.providers_from_config(:all)
      end
    end
  end

  describe "load/1" do
    setup do
      on_exit(fn ->
        try do
          :persistent_term.erase({Omni, :test_provider})
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "loads models into persistent_term under the module's id" do
      Provider.load([Omni.Providers.OpenAI])

      models = :persistent_term.get({Omni, :openai})
      assert is_map(models)
      assert map_size(models) > 0
      assert %Omni.Model{} = models |> Map.values() |> hd()
    end

    test "loads a custom provider" do
      ExUnit.CaptureLog.capture_log(fn -> Provider.load([TestProvider]) end)

      models = :persistent_term.get({Omni, :test_provider})
      assert models == %{}
    end

    test "merges with existing entries" do
      :persistent_term.put({Omni, :test_provider}, %{"existing" => :kept})

      ExUnit.CaptureLog.capture_log(fn -> Provider.load([TestProvider]) end)

      models = :persistent_term.get({Omni, :test_provider})
      assert models["existing"] == :kept
    end

    test "raises when two modules declare the same id" do
      ExUnit.CaptureLog.capture_log(fn -> Provider.load([TestProvider]) end)

      assert_raise ArgumentError, ~r/already registered by Omni.ProviderTest.TestProvider/, fn ->
        Provider.load([DuplicateIdProvider])
      end
    end
  end
end
