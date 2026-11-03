defmodule Omni.Providers.MistralTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Mistral
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Mistral.config())

      assert config.dialects[Omni.Dialects.OpenAICompletions][:base_url] ==
               "https://api.mistral.ai/v1"

      assert config.api_key == {:system, "MISTRAL_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:mistral)

      assert provider.module == Mistral
      assert Map.keys(provider.dialects) == [Omni.Dialects.OpenAICompletions]
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAICompletions}
      end
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:mistral)

      assert provider.dialects[Omni.Dialects.OpenAICompletions].compat == %{
               max_tokens_field: "max_tokens",
               thinking_replay_format: :content_chunks
             }
    end
  end
end
