defmodule Omni.Providers.GroqTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Groq
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(Groq.config())

      assert config.base_url == "https://api.groq.com/openai/v1"
      assert config.api_key == {:system, "GROQ_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:groq)

      assert provider.module == Groq
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
    defp model(id, thinking), do: Omni.Model.new(id: id, name: id, thinking: thinking)
    defp modify(body, model), do: Groq.modify_body(body, model, %Omni.Context{}, %{})

    test "asks reasoning models for parsed reasoning, whether or not thinking is set" do
      qwen = model("qwen/qwen3.6-27b", %{efforts: ["none", "default"]})

      assert modify(%{"reasoning_effort" => "default"}, qwen)["reasoning_format"] == "parsed"
      assert modify(%{}, qwen)["reasoning_format"] == "parsed"
    end

    test "leaves thinking-off requests untouched" do
      qwen = model("qwen/qwen3.6-27b", %{efforts: ["none", "default"]})
      body = %{"reasoning_effort" => "none"}

      assert modify(body, qwen) == body
    end

    test "leaves gpt-oss and non-reasoning models untouched" do
      body = %{"reasoning_effort" => "high"}

      assert modify(body, model("openai/gpt-oss-120b", %{efforts: ["low", "high"]})) == body
      assert modify(%{}, model("llama-3.3-70b-versatile", false)) == %{}
    end
  end
end
