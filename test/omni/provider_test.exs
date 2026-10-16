defmodule Omni.ProviderTest do
  use ExUnit.Case, async: true

  alias Omni.Provider
  alias Omni.Test.Fixtures

  defmodule HookModule do
    @behaviour Omni.Provider

    @impl true
    def modify_body(body, _model, _context, _opts), do: body
  end

  describe "get/1" do
    test "returns a loaded provider" do
      assert {:ok, %Provider{id: :anthropic, base_url: "https://api.anthropic.com/v1"}} =
               Provider.get(:anthropic)
    end

    test "returns an error for a provider that isn't loaded" do
      assert {:error, {:unknown_provider, :nonexistent}} = Provider.get(:nonexistent)
    end
  end

  describe "builtins/0" do
    test "lists the built-in provider ids" do
      ids = Provider.builtins()

      assert :anthropic in ids
      assert :ollama_cloud in ids
      assert length(ids) == 13
    end
  end

  describe "load/1" do
    test "stores the provider and its models" do
      id = Fixtures.load_provider(models: ["model-a", "model-b"])

      assert {:ok, %Provider{id: ^id, tier: :custom} = provider} = Provider.get(id)
      models = :persistent_term.get(Provider.models_key(id))

      assert Map.keys(models) |> Enum.sort() == ["model-a", "model-b"]
      assert Enum.all?(Map.values(models), &(&1.provider == provider))
    end

    test "stores an empty model map for a provider with no models" do
      id = Fixtures.load_provider()

      assert :persistent_term.get(Provider.models_key(id)) == %{}
      assert {:ok, []} = Omni.list_models(id)
    end

    test "reloading an id replaces its provider and models" do
      id = Fixtures.load_provider(models: ["old"])

      :ok =
        Provider.load([
          {id,
           base_url: "https://other.test/v1",
           dialects: %{text: Omni.Dialects.OpenAICompletions},
           models: ["new"]}
        ])

      assert {:ok, %Provider{base_url: "https://other.test/v1"}} = Provider.get(id)
      assert {:ok, [%Omni.Model{id: "new"}]} = Omni.list_models(id)
    end

    test "raises for a provider that can't be assembled" do
      assert_raise ArgumentError, ~r/no base_url/, fn ->
        Provider.load([:"unknown_#{System.unique_integer([:positive])}"])
      end
    end
  end

  describe "callback?/3" do
    test "reports whether the provider's module exports a callback" do
      provider = Fixtures.provider(module: HookModule)

      assert Provider.callback?(provider, :modify_body, 4)
      refute Provider.callback?(provider, :modify_deltas, 3)
      refute Provider.callback?(Fixtures.provider(), :modify_body, 4)
    end
  end

  describe "resolve_auth/1" do
    test "returns literal string as-is" do
      assert {:ok, "sk-literal"} = Provider.resolve_auth("sk-literal")
    end

    test "resolves {:system, env_var} from environment" do
      System.put_env("OMNI_TEST_RESOLVE_KEY", "sk-from-env")
      assert {:ok, "sk-from-env"} = Provider.resolve_auth({:system, "OMNI_TEST_RESOLVE_KEY"})
    after
      System.delete_env("OMNI_TEST_RESOLVE_KEY")
    end

    test "returns error when {:system, env_var} is not set" do
      assert {:error, {:missing_env_var, "OMNI_TEST_DEFINITELY_NOT_SET"}} =
               Provider.resolve_auth({:system, "OMNI_TEST_DEFINITELY_NOT_SET"})
    end

    test "resolves MFA tuple via apply" do
      assert {:ok, "hello"} = Provider.resolve_auth({String, :downcase, ["HELLO"]})
    end

    test "returns error when MFA raises" do
      assert {:error, %ArgumentError{}} =
               Provider.resolve_auth({String, :to_existing_atom, ["omni_no_such_atom_xyz"]})
    end

    test "returns error when MFA returns non-string" do
      assert {:error, {:invalid_auth_value, 3}} =
               Provider.resolve_auth({String, :length, ["abc"]})
    end

    test "returns {:error, :no_api_key} for nil" do
      assert {:error, :no_api_key} = Provider.resolve_auth(nil)
    end
  end
end
