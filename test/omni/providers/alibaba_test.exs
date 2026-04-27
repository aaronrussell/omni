defmodule Omni.Providers.AlibabaTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.Alibaba

  describe "config/0" do
    test "returns expected configuration" do
      config = Alibaba.config()

      assert config.base_url == "https://dashscope-intl.aliyuncs.com/compatible-mode"
      assert config.api_key == {:system, "DASHSCOPE_API_KEY"}
      refute Map.has_key?(config, :auth_header)
    end
  end

  describe "dialect/0" do
    test "returns OpenAICompletions dialect" do
      assert Alibaba.dialect() == Omni.Dialects.OpenAICompletions
    end
  end

  describe "models/0" do
    test "returns a non-empty list of Model structs" do
      models = Alibaba.models()

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Omni.Model{}, &1))
    end

    test "stamps provider and dialect on every model" do
      for model <- Alibaba.models() do
        assert model.provider == Alibaba
        assert model.dialect == Omni.Dialects.OpenAICompletions
      end
    end
  end

  describe "modify_body/3 — reasoning_effort" do
    test "translates reasoning_effort=none to enable_thinking false" do
      body = %{"model" => "qwen3.6-plus", "reasoning_effort" => "none"}

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      assert result["enable_thinking"] == false
      refute Map.has_key?(result, "reasoning_effort")
      refute Map.has_key?(result, "thinking_budget")
    end

    test "translates positive efforts to enable_thinking true with budget" do
      levels = %{
        "low" => 1024,
        "medium" => 4096,
        "high" => 16384,
        "xhigh" => 24576
      }

      for {level, expected_budget} <- levels do
        body = %{"model" => "qwen3.6-plus", "reasoning_effort" => level}

        result = Alibaba.modify_body(body, %Omni.Context{}, %{})

        assert result["enable_thinking"] == true,
               "expected #{level} to enable thinking"

        assert result["thinking_budget"] == expected_budget,
               "expected #{level} to set budget #{expected_budget}, got #{result["thinking_budget"]}"

        refute Map.has_key?(result, "reasoning_effort")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "qwen3.6-plus", "messages" => []}

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      refute Map.has_key?(result, "enable_thinking")
      refute Map.has_key?(result, "thinking_budget")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end

  describe "modify_body/3 — structured output" do
    test "rewrites json_schema response_format to json_object with system instruction" do
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

      body = %{
        "model" => "qwen3.6-plus",
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"schema" => schema}
        },
        "messages" => [%{"role" => "user", "content" => "Give me a name"}]
      }

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      assert result["response_format"] == %{"type" => "json_object"}

      [system, user] = result["messages"]
      assert system["role"] == "system"
      assert system["content"] =~ "Respond with JSON matching this schema"
      assert system["content"] =~ "\"name\""
      assert user["role"] == "user"
    end

    test "appends to existing system message" do
      schema = %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}

      body = %{
        "model" => "qwen3.6-plus",
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"schema" => schema}
        },
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Pick a number"}
        ]
      }

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      [system, user] = result["messages"]
      assert system["content"] =~ "You are helpful."
      assert system["content"] =~ "Respond with JSON matching this schema"
      assert user["content"] == "Pick a number"
    end

    test "passes through body without json_schema response_format" do
      body = %{
        "model" => "qwen3.6-plus",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      refute Map.has_key?(result, "response_format")
    end
  end

  describe "modify_body/3 — combined" do
    test "applies both reasoning_effort and structured output transforms" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

      body = %{
        "model" => "qwen3.6-plus",
        "reasoning_effort" => "high",
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"schema" => schema}
        },
        "messages" => [%{"role" => "user", "content" => "Test"}]
      }

      result = Alibaba.modify_body(body, %Omni.Context{}, %{})

      assert result["enable_thinking"] == true
      assert result["thinking_budget"] == 16384
      refute Map.has_key?(result, "reasoning_effort")
      assert result["response_format"] == %{"type" => "json_object"}
      assert [%{"role" => "system"}, %{"role" => "user"}] = result["messages"]
    end
  end
end
