defmodule Omni.Providers.AlibabaTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Alibaba
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Alibaba.config())

      assert config.base_url == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
      assert config.api_key == {:system, "DASHSCOPE_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:alibaba)

      assert provider.module == Alibaba
      assert provider.tier == :verified
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:alibaba)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{
                 thinking_toggle_format: :enable_thinking,
                 thinking_budget_field: "thinking_budget",
                 output_format: :json_object
               }
             }
    end
  end
end
