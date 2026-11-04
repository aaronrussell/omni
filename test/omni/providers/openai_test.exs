defmodule Omni.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenAI
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenAI.config())

      assert config.dialects[Omni.Dialects.OpenAIResponses][:base_url] ==
               "https://api.openai.com/v1"

      assert config.api_key == {:system, "OPENAI_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAIResponses dialect" do
      {provider, models} = Loader.assemble(:openai)

      assert provider.module == OpenAI

      assert Enum.sort(Map.keys(provider.dialects)) == [
               Omni.Dialects.OpenAIDecisions,
               Omni.Dialects.OpenAIResponses
             ]

      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects.text == Omni.Dialects.OpenAIResponses
      end
    end

    test "gpt-6-luna also serves decisions" do
      {provider, models} = Loader.assemble(:openai)
      luna = Enum.find(models, &(&1.id == "gpt-6-luna"))

      assert luna.dialects == %{
               text: Omni.Dialects.OpenAIResponses,
               decision: Omni.Dialects.OpenAIDecisions
             }

      assert provider.dialects[Omni.Dialects.OpenAIDecisions].base_url ==
               "https://api.openai.com/v1"

      others = Enum.reject(models, &(&1.id == "gpt-6-luna"))
      refute Enum.any?(others, &Omni.Model.capability?(&1, :decision))
    end
  end

  describe "models/2" do
    test "stamps the decision dialect without adding models" do
      luna =
        Omni.Model.new(
          id: "gpt-6-luna",
          name: "GPT-6 Luna",
          dialects: %{text: Omni.Dialects.OpenAIResponses}
        )

      other =
        Omni.Model.new(
          id: "gpt-6",
          name: "GPT-6",
          dialects: %{text: Omni.Dialects.OpenAIResponses}
        )

      assert [
               %{dialects: %{decision: Omni.Dialects.OpenAIDecisions}},
               %{dialects: other_dialects}
             ] =
               OpenAI.models([luna, other], nil)

      assert other_dialects == %{text: Omni.Dialects.OpenAIResponses}
      assert OpenAI.models([other], nil) == [other]
      assert OpenAI.models([], nil) == []
    end
  end
end
