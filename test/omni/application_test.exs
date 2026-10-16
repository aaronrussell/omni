defmodule Omni.ApplicationTest do
  use ExUnit.Case, async: false

  alias Omni.{Model, Provider}

  describe "loading at startup" do
    test "every built-in provider is loaded" do
      for id <- Provider.builtins() do
        assert {:ok, %Provider{id: ^id, tier: :verified}} = Provider.get(id)
        assert is_map(:persistent_term.get(Provider.models_key(id), nil))
      end
    end

    test "models are keyed by id and embed their loaded provider" do
      {:ok, provider} = Provider.get(:anthropic)
      models = :persistent_term.get(Provider.models_key(:anthropic))

      assert map_size(models) > 0

      for {id, model} <- models do
        assert id == model.id
        assert %Model{provider: ^provider} = model
      end
    end

    test "providers are loaded under their canonical ids" do
      assert {:ok, models} = Model.list(:moonshotai)
      assert models != []
      assert {:ok, models} = Model.list(:ollama_cloud)
      assert models != []

      # local Ollama is registered too (other tests may put models into it)
      assert {:ok, _models} = Model.list(:ollama)
    end
  end

  describe "config validation at boot" do
    # capture_log — stopping and failing to start :omni emits notice-level
    # application-exit reports.
    @describetag capture_log: true

    defp boot_error(key, value) do
      Application.put_env(:omni, key, value)

      on_exit(fn ->
        Application.delete_env(:omni, key)
        {:ok, _} = Application.ensure_all_started(:omni)
      end)

      :ok = Application.stop(:omni)
      assert {:error, reason} = Application.start(:omni)
      inspect(reason)
    end

    test "the legacy :providers list raises with a migration message" do
      assert boot_error(:providers, [:anthropic, :openai]) =~ "now configures providers by id"
    end

    test "v1 per-module provider config raises with a migration message" do
      message = boot_error(Omni.Providers.OpenAI, api_key: "sk")

      assert message =~ "is no longer read"
      assert message =~ "openai:"
    end
  end
end
