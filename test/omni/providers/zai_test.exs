defmodule Omni.Providers.ZaiTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Zai
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Zai.config())

      assert config.base_url == "https://api.z.ai/api/paas/v4"
      assert config.api_key == {:system, "ZAI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:zai)

      assert provider.module == Zai
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
      {provider, _models} = Loader.assemble(:zai)

      assert provider.compat == %{
               Omni.Dialects.OpenAICompletions => %{
                 max_tokens_field: "max_tokens",
                 thinking_toggle_format: :thinking_type,
                 output_format: :json_object,
                 attachment_format: :file_url
               }
             }
    end
  end
end
