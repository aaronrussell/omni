defmodule Omni.Providers.TypeSafeTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.TypeSafe
  alias Omni.Provider.Loader

  @system_one Omni.Dialects.SystemOne

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(TypeSafe.config())

      assert config.dialects[@system_one][:base_url] == "https://api.typesafe.ai/v1"
      assert config.api_key == {:system, "TYPESAFE_API_KEY"}
    end
  end

  describe "assembled provider" do
    # models.dev has no TypeSafe entry, so the module's list is the catalog.
    test "loads TypeSafe's documented models over System One" do
      {provider, models} = Loader.assemble(:typesafe)

      assert provider.module == TypeSafe
      assert Enum.sort(Map.keys(provider.dialects)) == [@system_one]
      assert provider.dialects[@system_one].base_url == "https://api.typesafe.ai/v1"

      assert Enum.map(models, & &1.id) ==
               ["jev-1.13.0", "jev-1.14.0", "jev-latest", "jev-preview"]

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{decision: @system_one}
        assert model.input_cost == 0.042
        assert model.output_cost == 0
      end
    end

    # The documented list isn't catalog data: a config entry with a listed id
    # replaces the documented model rather than merging over it.
    test "a config model adds to the documented list, or replaces a listed one" do
      {_provider, models} =
        Loader.assemble(:typesafe,
          models: [
            [id: "jev-1.15.0", dialects: %{decision: @system_one}],
            [id: "jev-latest", dialects: %{decision: @system_one}, context_size: 262_144]
          ]
        )

      by_id = Map.new(models, &{&1.id, &1})

      assert Map.keys(by_id) |> Enum.sort() ==
               ["jev-1.13.0", "jev-1.14.0", "jev-1.15.0", "jev-latest", "jev-preview"]

      assert by_id["jev-latest"].context_size == 262_144
      assert by_id["jev-latest"].input_cost == 0
    end

    test "a config model without a dialect raises with a decision hint" do
      assert_raise ArgumentError, ~r/dialects: %\{decision: Omni.Dialects.SystemOne\}/, fn ->
        Loader.assemble(:typesafe, models: ["jev-1.15.0"])
      end
    end
  end

  describe "models/2" do
    test "fills in documented ids the given models lack, keeping theirs" do
      given = Omni.Model.new(id: "jev-latest", name: "Jev", dialects: %{decision: @system_one})
      models = TypeSafe.models([given], nil)

      assert hd(models) == given

      assert Enum.map(models, & &1.id) == [
               "jev-latest",
               "jev-1.14.0",
               "jev-1.13.0",
               "jev-preview"
             ]
    end
  end
end
