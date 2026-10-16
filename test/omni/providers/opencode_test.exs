defmodule Omni.Providers.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenCode
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenCode.config())

      assert config.base_url == "https://opencode.ai/zen/v1"
      assert config.api_key == {:system, "OPENCODE_API_KEY"}
      refute Map.has_key?(config, :dialects)
    end
  end

  describe "assembled provider" do
    test "derives its dialects from its models" do
      {provider, models} = Loader.assemble(:opencode)

      assert provider.module == OpenCode
      assert provider.auth == :dialect

      assert Enum.sort(provider.dialects.text) ==
               Enum.sort([
                 Omni.Dialects.AnthropicMessages,
                 Omni.Dialects.GoogleGemini,
                 Omni.Dialects.OpenAICompletions,
                 Omni.Dialects.OpenAIResponses
               ])

      by_id = Map.new(models, &{&1.id, &1.dialects.text})
      assert by_id["claude-haiku-4-5"] == Omni.Dialects.AnthropicMessages
      assert by_id["gpt-5.2"] == Omni.Dialects.OpenAIResponses
      assert by_id["kimi-k2.5"] == Omni.Dialects.OpenAICompletions
      assert by_id["gemini-3-flash"] == Omni.Dialects.GoogleGemini
    end

    test "skips models whose npm package maps to no dialect" do
      {_provider, models} = Loader.assemble(:opencode)

      refute Enum.any?(models, &(&1.id == "mistral-large-4"))
    end
  end
end
