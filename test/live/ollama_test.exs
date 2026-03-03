defmodule Live.OllamaTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Message, Response}
  alias Omni.Content.{Text, Thinking, ToolUse}

  setup_all do
    model =
      Omni.Model.new(
        id: "qwen3.5:4b",
        name: "qwen3.5:4b",
        provider: Omni.Providers.Ollama,
        dialect: Omni.Dialects.OllamaChat,
        reasoning: true
      )

    Omni.Model.put(:ollama, model)
    :ok
  end

  defp model do
    {:ok, model} = Omni.get_model(:ollama, "qwen3.5:4b")
    model
  end

  test "text generation" do
    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model(), "Write a haiku about the sky.",
               thinking: false,
               max_tokens: 200
             )

    assert resp.stop_reason in [:stop, :length]
    texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
    assert length(texts) > 0
    text = hd(texts).text
    assert is_binary(text) and text != ""

    truncated = if String.length(text) > 80, do: String.slice(text, 0, 80) <> "...", else: text
    truncated = String.replace(truncated, "\n", " ")

    IO.puts(
      "[ollama] text: \"#{truncated}\" (stop: #{resp.stop_reason}, in: #{resp.usage.input_tokens}, out: #{resp.usage.output_tokens})"
    )
  end

  test "tool use" do
    tool =
      Omni.tool(
        name: "get_weather",
        description: "Gets the weather for a given city",
        input_schema: %{type: "object", properties: %{city: %{type: "string"}}}
      )

    context =
      Context.new(
        messages: [Message.new("What is the weather in London?")],
        tools: [tool]
      )

    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model(), context, thinking: false)

    assert length(resp.message.content) > 0
    assert resp.message.role == :assistant

    case Enum.filter(resp.message.content, &match?(%ToolUse{}, &1)) do
      [tool_use | _] ->
        IO.puts(
          "[ollama] tool: #{tool_use.name}(#{inspect(tool_use.input)}) (stop: #{resp.stop_reason})"
        )

      [] ->
        text = Enum.find(resp.message.content, &match?(%Text{}, &1))
        truncated = String.slice(text.text, 0, 80)
        IO.puts("[ollama] tool (text fallback): \"#{truncated}\" (stop: #{resp.stop_reason})")
    end
  end

  test "thinking" do
    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model(), "How many R's are in strawberry?",
               thinking: true,
               max_tokens: 2000
             )

    thinking = Enum.filter(resp.message.content, &match?(%Thinking{}, &1))
    assert length(thinking) > 0
    thinking_text = hd(thinking).text || ""

    texts = Enum.filter(resp.message.content, &match?(%Text{}, &1))
    assert length(texts) > 0
    answer = hd(texts).text

    truncated =
      if String.length(thinking_text) > 200,
        do: String.slice(thinking_text, 0, 200) <> "...",
        else: thinking_text

    truncated = String.replace(truncated, "\n", " ")

    IO.puts("[ollama] thinking: \"#{truncated}\" (#{String.length(thinking_text)} chars)")
    IO.puts("[ollama] answer: \"#{String.replace(answer, "\n", " ")}\"")
  end
end
