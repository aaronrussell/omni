defmodule Omni.Providers.VeniceTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Venice
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Venice.config())

      assert config.base_url == "https://api.venice.ai/api/v1"
      assert config.api_key == {:system, "VENICE_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:venice)

      assert provider.module == Venice
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end

    test "injects :pdf into input_modalities on every model, once" do
      {_provider, models} = Loader.assemble(:venice)

      for model <- models do
        assert Enum.count(model.input_modalities, &(&1 == :pdf)) == 1,
               "expected exactly one :pdf entry on #{model.id}"
      end
    end
  end

  describe "models/2" do
    test "adds :pdf without duplicating it" do
      models = [
        Omni.Model.new(id: "a", name: "A", input_modalities: [:text]),
        Omni.Model.new(id: "b", name: "B", input_modalities: [:text, :pdf])
      ]

      assert [a, b] = Venice.models(models, nil)
      assert a.input_modalities == [:pdf, :text]
      assert b.input_modalities == [:text, :pdf]
    end
  end

  describe "modify_body/4" do
    test "converts reasoning_effort none to reasoning enabled: false" do
      body = %{"model" => "qwen3-6-27b", "reasoning_effort" => "none"}

      result = Venice.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning"] == %{"enabled" => false}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "leaves positive reasoning_effort values untouched" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "qwen3-6-27b", "reasoning_effort" => level}

        result = Venice.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == level
        refute Map.has_key?(result, "reasoning")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "qwen3-6-27b", "messages" => []}

      result = Venice.modify_body(body, nil, %Omni.Context{}, %{})

      refute Map.has_key?(result, "reasoning")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
