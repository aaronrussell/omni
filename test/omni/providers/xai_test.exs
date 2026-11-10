defmodule Omni.Providers.XAITest do
  use ExUnit.Case, async: true

  alias Omni.Providers.XAI
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(XAI.config())

      assert config.dialects[Omni.Dialects.OpenAIResponses][:base_url] == "https://api.x.ai/v1"
      assert config.api_key == {:system, "XAI_API_KEY"}
    end
  end

  describe "models/2" do
    # llm_db describes xAI's Chat Completions endpoint.
    test "re-stamps Completions models with the Responses dialect" do
      model =
        Omni.Model.new(
          id: "grok-4.3",
          name: "Grok 4.3",
          dialects: %{text: Omni.Dialects.OpenAICompletions}
        )

      assert [%{dialects: %{text: Omni.Dialects.OpenAIResponses}}] = XAI.models([model], nil)
    end

    test "gives a config model with no dialect Responses, and leaves decision models alone" do
      bare = Omni.Model.new(id: "grok-new", name: "grok-new")

      decision =
        Omni.Model.new(id: "d", name: "d", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne})

      assert [bare, ^decision] = XAI.models([bare, decision], nil)
      assert bare.dialects == %{text: Omni.Dialects.OpenAIResponses}
    end
  end

  describe "modify_body/4" do
    @body %{"model" => "m", "reasoning" => %{"effort" => "none"}}

    test "drops reasoning on models with no effort data" do
      model = Omni.Model.new(id: "m", name: "m", thinking: true)
      assert XAI.modify_body(@body, model, nil, []) == %{"model" => "m"}
    end

    test "keeps reasoning on models with effort data" do
      model = Omni.Model.new(id: "m", name: "m", thinking: %{efforts: ["none", "low"]})
      assert XAI.modify_body(@body, model, nil, []) == @body
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAIResponses dialect" do
      {provider, models} = Loader.assemble(:xai)

      assert provider.module == XAI
      assert Map.keys(provider.dialects) == [Omni.Dialects.OpenAIResponses]
      assert provider.dialects[Omni.Dialects.OpenAIResponses].compat == %{}
      assert models != []

      for model <- models do
        assert model.provider == provider
        assert model.dialects == %{text: Omni.Dialects.OpenAIResponses}
      end
    end
  end
end
