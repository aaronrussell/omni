defmodule Omni.ApplicationTest do
  use ExUnit.Case, async: false

  describe "load_providers at startup" do
    test "default providers are loaded into :persistent_term" do
      # Application already started — anthropic should be loaded
      models = :persistent_term.get({Omni, :anthropic}, nil)

      assert is_map(models)
      assert map_size(models) > 0

      for {id, model} <- models do
        assert is_binary(id)
        assert %Omni.Model{} = model
        assert model.provider == Omni.Providers.Anthropic
      end
    end

    test "model map is keyed by model ID" do
      models = :persistent_term.get({Omni, :anthropic})

      for {id, model} <- models do
        assert id == model.id
      end
    end

    test "renamed and split providers are loaded under their canonical ids" do
      assert map_size(:persistent_term.get({Omni, :moonshotai}, %{})) > 0
      assert map_size(:persistent_term.get({Omni, :ollama_cloud}, %{})) > 0

      # local Ollama is registered too (other tests may put models into it)
      assert is_map(:persistent_term.get({Omni, :ollama}, nil))
    end

    test "openai models are loaded into :persistent_term" do
      models = :persistent_term.get({Omni, :openai}, nil)

      assert is_map(models)
      assert map_size(models) > 0

      for {id, model} <- models do
        assert is_binary(id)
        assert %Omni.Model{} = model
        assert model.provider == Omni.Providers.OpenAI
      end
    end

    # capture_log — stopping and failing to start :omni emits notice-level
    # application-exit reports.
    @tag capture_log: true
    test "the legacy :providers config key raises with a migration message at boot" do
      Application.put_env(:omni, :providers, [:anthropic])

      on_exit(fn ->
        Application.delete_env(:omni, :providers)
        {:ok, _} = Application.ensure_all_started(:omni)
      end)

      :ok = Application.stop(:omni)

      assert {:error, reason} = Application.start(:omni)
      assert inspect(reason) =~ "moved from :providers to :models"
    end
  end
end
