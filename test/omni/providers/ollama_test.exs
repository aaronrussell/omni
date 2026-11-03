defmodule Omni.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Ollama
  alias Omni.Provider.Loader

  describe "config/0" do
    test "targets localhost with no auth and the native dialect" do
      config = Map.new(Ollama.config())

      assert config.dialects[Omni.Dialects.OllamaChat][:base_url] == "http://localhost:11434"
      assert config.auth == :none
      refute Map.has_key?(config, :api_key)
    end
  end

  describe "assembled provider" do
    test "loads no models without a models: entry" do
      # A local instance's models are unknowable to any catalog — they come
      # from config only.
      assert {provider, []} = Loader.assemble(:ollama)
      assert provider.module == Ollama
      assert provider.auth == :none
      assert Map.keys(provider.dialects) == [Omni.Dialects.OllamaChat]
    end

    test "builds a model from a string id" do
      {provider, [model]} = Loader.assemble(:ollama, models: ["qwen3.5:4b"])

      assert model.id == "qwen3.5:4b"
      assert model.name == "qwen3.5:4b"
      assert model.provider == provider
      assert model.dialects == %{text: Omni.Dialects.OllamaChat}
    end

    test "builds a model from a keyword list" do
      {_provider, [model]} =
        Loader.assemble(:ollama,
          models: [
            [
              id: "llama3.1:8b",
              name: "Llama 3.1 8B",
              context_size: 128_000,
              max_output_tokens: 8192
            ]
          ]
        )

      assert model.id == "llama3.1:8b"
      assert model.name == "Llama 3.1 8B"
      assert model.context_size == 128_000
      assert model.max_output_tokens == 8192
      assert model.dialects == %{text: Omni.Dialects.OllamaChat}
    end

    test "mixes string and keyword list entries" do
      {_provider, [m1, m2]} =
        Loader.assemble(:ollama,
          models: ["mistral:7b", [id: "qwen3.5:4b", name: "Qwen 3.5 4B", thinking: true]]
        )

      assert m1.id == "mistral:7b"
      assert m1.name == "mistral:7b"
      assert m2.id == "qwen3.5:4b"
      assert m2.name == "Qwen 3.5 4B"
      assert m2.thinking == true
    end

    test "keeps a dialect a model names" do
      completions = Omni.Dialects.OpenAICompletions

      {_provider, [model]} =
        Loader.assemble(:ollama,
          dialects: %{completions => [base_url: "http://localhost:11434/v1"]},
          models: [[id: "qwen3.5:4b", dialects: %{text: completions}]]
        )

      assert model.dialects == %{text: completions}
    end

    test "host: moves the endpoint to another box" do
      {provider, _} = Loader.assemble(:ollama, host: "http://gpu-box:11434")

      assert provider.dialects[Omni.Dialects.OllamaChat].base_url == "http://gpu-box:11434"
    end
  end
end
