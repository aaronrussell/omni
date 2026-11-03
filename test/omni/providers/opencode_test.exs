defmodule Omni.Providers.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Omni.Providers.OpenCode
  alias Omni.Provider.Loader

  describe "config/0" do
    test "returns expected configuration" do
      config = Map.new(OpenCode.config())

      assert config.api_key == {:system, "OPENCODE_API_KEY"}
      # The catalog supplies the URLs; the module sets only compat.
      refute Keyword.has_key?(config.dialects[Omni.Dialects.OpenAICompletions], :base_url)
    end
  end

  describe "assembled provider" do
    test "derives its dialects from its models" do
      {provider, models} = Loader.assemble(:opencode)

      assert provider.module == OpenCode
      assert provider.auth == :dialect

      assert Enum.sort(Map.keys(provider.dialects)) ==
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
      # Zen serves Mistral models on Chat Completions
      assert by_id["mistral-large-4"] == Omni.Dialects.OpenAICompletions
    end
  end

  describe "compat" do
    test "assembles with its Completions flags" do
      {provider, _models} = Loader.assemble(:opencode)

      assert provider.dialects[Omni.Dialects.OpenAICompletions].compat == %{
               thinking_replay_format: :reasoning_content
             }

      for {_dialect, endpoint} <- provider.dialects do
        assert endpoint.base_url == "https://opencode.ai/zen/v1"
      end
    end
  end

  describe "modify_body/4" do
    defp modify(body, id),
      do: OpenCode.modify_body(body, Omni.Model.new(id: id, name: id), %Omni.Context{}, %{})

    defp assistant(fields), do: Map.merge(%{"role" => "assistant"}, fields)

    test "moves a Mistral model's reasoning into a leading thinking chunk" do
      tool_calls = [%{"id" => "call_1", "type" => "function"}]

      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Hi"},
          assistant(%{"content" => "Hello", "reasoning_content" => "Hmm."}),
          assistant(%{"reasoning_content" => "Tools.", "tool_calls" => tool_calls})
        ]
      }

      [user, answer, tool_use] = modify(body, "mistral-large-4")["messages"]

      thinking = &%{"type" => "thinking", "thinking" => [%{"type" => "text", "text" => &1}]}

      assert user == %{"role" => "user", "content" => "Hi"}

      assert answer ==
               assistant(%{
                 "content" => [thinking.("Hmm."), %{"type" => "text", "text" => "Hello"}]
               })

      assert tool_use ==
               assistant(%{"content" => [thinking.("Tools.")], "tool_calls" => tool_calls})
    end

    test "leaves Mistral messages without reasoning, and other models, untouched" do
      body = %{"messages" => [assistant(%{"content" => "Hello"})]}
      assert modify(body, "mistral-large-4") == body

      body = %{"messages" => [assistant(%{"content" => "Hello", "reasoning_content" => "Hmm."})]}
      assert modify(body, "glm-5.3") == body
    end
  end
end
