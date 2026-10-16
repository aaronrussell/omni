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

  describe "modify_body/4 — reasoning_effort" do
    test "translates reasoning_effort=none to thinking disabled" do
      body = %{"model" => "glm-4.7-flash", "reasoning_effort" => "none"}

      result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "translates any positive effort to thinking enabled" do
      for level <- ["low", "medium", "high", "xhigh"] do
        body = %{"model" => "glm-4.7-flash", "reasoning_effort" => level}

        result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["thinking"] == %{"type" => "enabled"},
               "expected #{level} to map to enabled"

        refute Map.has_key?(result, "reasoning_effort")
      end
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "glm-4.7-flash", "messages" => []}

      result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

      assert result == body
    end
  end

  describe "modify_body/4 — file attachments" do
    test "rewrites file blocks to file_url shape" do
      body = %{
        "model" => "glm-4.7-flash",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "Summarise"},
              %{
                "type" => "file",
                "file" => %{"file_data" => "data:application/pdf;base64,JVBERi0..."}
              }
            ]
          }
        ]
      }

      result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

      [%{"content" => [text, file]}] = result["messages"]
      assert text == %{"type" => "text", "text" => "Summarise"}

      assert file == %{
               "type" => "file_url",
               "file_url" => %{"url" => "data:application/pdf;base64,JVBERi0..."}
             }
    end

    test "leaves image_url and text blocks untouched" do
      body = %{
        "model" => "glm-4.7-flash",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "Hi"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/img.png"}}
            ]
          }
        ]
      }

      result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

      assert [%{"content" => content}] = result["messages"]
      assert content == hd(body["messages"])["content"]
    end

    test "passes through messages with string content" do
      body = %{
        "model" => "glm-4.7-flash",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      result = Zai.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["messages"] == body["messages"]
    end
  end
end
