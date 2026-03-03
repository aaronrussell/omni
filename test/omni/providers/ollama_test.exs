defmodule Omni.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Ollama

  describe "config/0" do
    test "returns localhost base_url and nil api_key" do
      config = Ollama.config()
      assert config.base_url == "http://localhost:11434"
      assert config.api_key == nil
    end
  end

  describe "dialect/0" do
    test "returns OllamaChat" do
      assert Ollama.dialect() == Omni.Dialects.OllamaChat
    end
  end

  describe "models/0" do
    test "returns a list of models from JSON" do
      models = Ollama.models()
      assert is_list(models) and length(models) > 0
    end

    test "all models have correct provider and dialect" do
      for model <- Ollama.models() do
        assert model.provider == Ollama
        assert model.dialect == Omni.Dialects.OllamaChat
      end
    end

    test "builds model from string shorthand" do
      Application.put_env(:omni, Ollama, models: ["qwen3.5:4b"])

      [model] = Ollama.models()
      assert model.id == "qwen3.5:4b"
      assert model.name == "qwen3.5:4b"
      assert model.provider == Ollama
      assert model.dialect == Omni.Dialects.OllamaChat
    after
      Application.delete_env(:omni, Ollama)
    end

    test "builds model from keyword list with full details" do
      Application.put_env(:omni, Ollama,
        models: [
          [
            id: "llama3.1:8b",
            name: "Llama 3.1 8B",
            context_size: 128_000,
            max_output_tokens: 8192
          ]
        ]
      )

      [model] = Ollama.models()
      assert model.id == "llama3.1:8b"
      assert model.name == "Llama 3.1 8B"
      assert model.context_size == 128_000
      assert model.max_output_tokens == 8192
      assert model.provider == Ollama
      assert model.dialect == Omni.Dialects.OllamaChat
    after
      Application.delete_env(:omni, Ollama)
    end

    test "mixes string and keyword list entries" do
      Application.put_env(:omni, Ollama,
        models: [
          "mistral:7b",
          [id: "qwen3.5:4b", name: "Qwen 3.5 4B", reasoning: true]
        ]
      )

      [m1, m2] = Ollama.models()
      assert m1.id == "mistral:7b"
      assert m1.name == "mistral:7b"
      assert m2.id == "qwen3.5:4b"
      assert m2.name == "Qwen 3.5 4B"
      assert m2.reasoning == true
    after
      Application.delete_env(:omni, Ollama)
    end
  end

  describe "authenticate/2" do
    test "passes through when api_key is nil" do
      req = Req.new()
      assert {:ok, ^req} = Ollama.authenticate(req, %{api_key: nil})
    end

    test "sets Bearer authorization header when api_key is provided" do
      req = Req.new()
      {:ok, authed} = Ollama.authenticate(req, %{api_key: "test-key-123"})
      assert Req.Request.get_header(authed, "authorization") == ["Bearer test-key-123"]
    end

    test "returns error when api_key is {:system, missing_var}" do
      req = Req.new()

      assert {:error, {:missing_env_var, _}} =
               Ollama.authenticate(req, %{api_key: {:system, "OMNI_TEST_NONEXISTENT_KEY"}})
    end
  end
end
