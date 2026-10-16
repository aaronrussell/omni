defmodule Omni.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Omni.{Context, Message}
  alias Omni.Providers.OpenRouter
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenRouter.config())

      assert config.base_url == "https://openrouter.ai/api/v1"
      assert config.api_key == {:system, "OPENROUTER_API_KEY"}
    end
  end

  describe "assembled provider" do
    test "loads catalog models with the OpenAICompletions dialect" do
      {provider, models} = Loader.assemble(:openrouter)

      assert provider.module == OpenRouter
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
    test "converts reasoning_effort to reasoning object" do
      body = %{"model" => "test", "reasoning_effort" => "high"}

      result = OpenRouter.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning"] == %{"effort" => "high"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "passes through xhigh effort unchanged" do
      body = %{"model" => "test", "reasoning_effort" => "xhigh"}

      result = OpenRouter.modify_body(body, nil, %Omni.Context{}, %{})

      assert result["reasoning"] == %{"effort" => "xhigh"}
    end

    test "passes through body without reasoning_effort" do
      body = %{"model" => "test", "messages" => []}

      result = OpenRouter.modify_body(body, nil, %Omni.Context{}, %{})

      assert result == body
    end

    test "passes through other effort levels unchanged" do
      for level <- ["low", "medium", "high"] do
        body = %{"model" => "test", "reasoning_effort" => level}

        result = OpenRouter.modify_body(body, nil, %Omni.Context{}, %{})

        assert result["reasoning"]["effort"] == level,
               "expected #{level} to pass through"
      end
    end
  end

  describe "modify_body/4 — reasoning_details outbound" do
    test "attaches reasoning_details from assistant message private data" do
      context =
        Context.new([
          Message.new(role: :user, content: "Hello"),
          Message.new(
            role: :assistant,
            content: "Hi there",
            private: %{
              reasoning_details: [
                %{"type" => "reasoning.summary", "summary" => "thinking"},
                %{"type" => "reasoning.encrypted", "data" => "blob"}
              ]
            }
          ),
          Message.new(role: :user, content: "Follow up")
        ])

      body = %{
        "model" => "test",
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"},
          %{"role" => "user", "content" => "Follow up"}
        ]
      }

      result = OpenRouter.modify_body(body, nil, context, %{})

      assert [user1, assistant, user2] = result["messages"]
      refute Map.has_key?(user1, "reasoning_details")
      refute Map.has_key?(user2, "reasoning_details")

      assert assistant["reasoning_details"] == [
               %{"type" => "reasoning.summary", "summary" => "thinking"},
               %{"type" => "reasoning.encrypted", "data" => "blob"}
             ]
    end

    test "does not attach reasoning_details when private is empty" do
      context =
        Context.new([
          Message.new(role: :user, content: "Hello"),
          Message.new(role: :assistant, content: "Hi there"),
          Message.new(role: :user, content: "Follow up")
        ])

      body = %{
        "model" => "test",
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"},
          %{"role" => "user", "content" => "Follow up"}
        ]
      }

      result = OpenRouter.modify_body(body, nil, context, %{})

      assistant = Enum.find(result["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(assistant, "reasoning_details")
    end

    test "chains with reasoning_effort transform" do
      context =
        Context.new([
          Message.new(
            role: :assistant,
            content: "Hi",
            private: %{reasoning_details: [%{"type" => "reasoning.encrypted", "data" => "x"}]}
          ),
          Message.new(role: :user, content: "Follow up")
        ])

      body = %{
        "model" => "test",
        "reasoning_effort" => "high",
        "messages" => [
          %{"role" => "assistant", "content" => "Hi"},
          %{"role" => "user", "content" => "Follow up"}
        ]
      }

      result = OpenRouter.modify_body(body, nil, context, %{})

      assert result["reasoning"] == %{"effort" => "high"}
      refute Map.has_key?(result, "reasoning_effort")

      assistant = Enum.find(result["messages"], &(&1["role"] == "assistant"))
      assert assistant["reasoning_details"] == [%{"type" => "reasoning.encrypted", "data" => "x"}]
    end
  end

  describe "modify_deltas/3" do
    test "extracts reasoning_details from raw SSE event" do
      details = [%{"type" => "reasoning.summary", "summary" => "thinking"}]

      raw_event = %{
        "choices" => [
          %{"delta" => %{"reasoning_details" => details, "content" => ""}}
        ]
      }

      result = OpenRouter.modify_deltas([], raw_event, nil)

      assert [{:message, %{private: %{reasoning_details: ^details}}}] = result
    end

    test "passes through when reasoning_details absent" do
      raw_event = %{
        "choices" => [%{"delta" => %{"content" => "hello"}}]
      }

      existing = [{:block_delta, %{type: :text, index: 0, delta: "hello"}}]
      result = OpenRouter.modify_deltas(existing, raw_event, nil)

      assert result == existing
    end

    test "passes through when reasoning_details is empty list" do
      raw_event = %{
        "choices" => [%{"delta" => %{"reasoning_details" => [], "content" => ""}}]
      }

      existing = [{:message, %{model: "test"}}]
      result = OpenRouter.modify_deltas(existing, raw_event, nil)

      assert result == existing
    end

    test "error in raw event replaces deltas" do
      raw_event = %{
        "error" => %{"code" => "server_error", "message" => "Provider disconnected"},
        "choices" => [%{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "error"}]
      }

      existing = [{:message, %{stop_reason: :stop}}]
      result = OpenRouter.modify_deltas(existing, raw_event, nil)

      assert [{:error, "Provider disconnected"}] = result
    end

    test "appends to existing deltas" do
      details = [%{"type" => "reasoning.encrypted", "data" => "blob"}]

      raw_event = %{
        "choices" => [%{"delta" => %{"reasoning_details" => details, "reasoning" => "text"}}]
      }

      existing = [{:block_delta, %{type: :thinking, index: 0, delta: "text"}}]
      result = OpenRouter.modify_deltas(existing, raw_event, nil)

      assert length(result) == 2
      assert List.first(result) == List.first(existing)
      assert {:message, %{private: %{reasoning_details: ^details}}} = List.last(result)
    end
  end
end
