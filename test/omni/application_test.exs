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
  end

end
