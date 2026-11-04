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
      assert {:ok, %Provider{id: :anthropic} = provider} = Provider.get(:anthropic)

      assert {:ok, %{base_url: "https://api.anthropic.com/v1"}} =
               Provider.endpoint(provider, Omni.Dialects.AnthropicMessages)
    end

    test "returns an error for a provider that isn't loaded" do
      assert {:error, {:unknown_provider, :nonexistent}} = Provider.get(:nonexistent)
    end
  end

  describe "endpoint/2" do
    test "returns an error for a dialect the provider has no endpoint for" do
      assert {:error, {:no_endpoint, Omni.Dialects.GoogleGemini}} =
               Provider.endpoint(Fixtures.provider(), Omni.Dialects.GoogleGemini)
    end
  end

  describe "dialects/2" do
    test "lists the provider's dialects for a capability" do
      provider = Fixtures.provider(dialect: Omni.Dialects.OpenAIResponses)
      assert Provider.dialects(provider, :text) == [Omni.Dialects.OpenAIResponses]
      assert Provider.dialects(provider, :decision) == []
    end
  end

  describe "builtins/0" do
    test "lists the built-in provider ids" do
      ids = Provider.builtins()

      assert :anthropic in ids
      assert :ollama_cloud in ids
      assert :typesafe in ids
      assert length(ids) == 17
    end
  end

  describe "load/1" do
    test "stores the provider and its models" do
      id = Fixtures.load_provider(models: ["model-a", "model-b"])

      assert {:ok, %Provider{id: ^id} = provider} = Provider.get(id)
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

      completions = Omni.Dialects.OpenAICompletions

      :ok =
        Provider.load([
          {id,
           dialects: %{completions => [base_url: "https://other.test/v1"]},
           models: [[id: "new", dialects: %{text: completions}]]}
        ])

      assert {:ok, provider} = Provider.get(id)
      assert provider.dialects[completions].base_url == "https://other.test/v1"
      assert {:ok, [%Omni.Model{id: "new"}]} = Omni.list_models(id)
    end

    test "raises for a provider that can't be assembled" do
      assert_raise ArgumentError, ~r/has no dialect/, fn ->
        Provider.load([{:"unknown_#{System.unique_integer([:positive])}", models: ["x"]}])
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
