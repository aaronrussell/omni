defmodule Omni.Providers.VeniceTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Venice

  describe "config/0" do
    test "returns expected configuration" do
      config = Venice.config()

      assert config.base_url == "https://api.venice.ai/api"
      assert config.api_key == {:system, "VENICE_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert Venice.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Venice.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Venice.models() do
        assert model.provider == Venice
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end

    test "injects :pdf into input_modalities on every model" do
      for model <- Venice.models() do
        assert :pdf in model.input_modalities,
               "expected #{model.id} to include :pdf in input_modalities"
      end
    end

    test "does not duplicate :pdf when a model already lists it" do
      for model <- Venice.models() do
        pdf_count = Enum.count(model.input_modalities, &(&1 == :pdf))

        assert pdf_count == 1,
               "expected exactly one :pdf entry on #{model.id}, got #{pdf_count}"
      end
    end
  end

  describe "modify_body/3" do
    test "converts reasoning_effort none to reasoning enabled: false" do
      body = %{"model" => "qwen3-6-27b", "reasoning_effort" => "none"}

      result = Venice.modify_body(body, %Omni.Context{}, %{})

      assert result["reasoning"] == %{"enabled" => false}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "leaves positive reasoning_effort values untouched" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "qwen3-6-27b", "reasoning_effort" => level}

        result = Venice.modify_body(body, %Omni.Context{}, %{})

        assert result["reasoning_effort"] == level
        refute Map.has_key?(result, "reasoning")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "qwen3-6-27b", "messages" => []}

      result = Venice.modify_body(body, %Omni.Context{}, %{})

      refute Map.has_key?(result, "reasoning")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
