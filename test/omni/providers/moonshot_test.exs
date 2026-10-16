defmodule Omni.Providers.MoonshotTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Moonshot
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Moonshot.config())

      assert config.base_url == "https://api.moonshot.ai/v1"
      assert config.api_key == {:system, "MOONSHOT_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:moonshotai)

      assert provider.module == Moonshot
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "modify_body/4" do
    test "converts reasoning_effort none to thinking disabled" do
      body = %{"model" => "kimi-k2.6", "reasoning_effort" => "none"}

      result = Moonshot.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "converts positive reasoning_effort to thinking enabled" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "kimi-k2.6", "reasoning_effort" => level}

        result = Moonshot.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["thinking"] == %{"type" => "enabled"},
               "expected #{level} to map to thinking enabled"

        refute Map.has_key?(result, "reasoning_effort")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "kimi-k2.6", "messages" => []}

      result = Moonshot.modify_body(body, nil, %Omni.Context{}, %{})

      refute Map.has_key?(result, "thinking")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
