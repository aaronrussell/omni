defmodule Live.OpenRouterTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Message, Provider, Response}
  alias Omni.Content.{Text, Thinking, ToolUse}

  setup_all do
    Provider.load([:openrouter])
    :ok
  end

  defp model do
    {:ok, model} = Omni.get_model(:openrouter, "openai/gpt-4.1-mini")
    model
  end

  defp reasoning_model do
    {:ok, model} = Omni.get_model(:openrouter, "openai/o4-mini")
    model
  end

  test "text generation" do
    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model(), "Write a haiku about why the sky is blue.")

    assert resp.stop_reason == :stop
    [%Text{text: text}] = resp.message.content
    assert is_binary(text) and text != ""

    truncated = if String.length(text) > 80, do: String.slice(text, 0, 80) <> "...", else: text
    truncated = String.replace(truncated, "\n", " ")

    IO.puts(
      "[openrouter] text: \"#{truncated}\" (stop: #{resp.stop_reason}, in: #{resp.usage.input_tokens}, out: #{resp.usage.output_tokens})"
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

    assert {:ok, %Response{} = resp} = Omni.generate_text(model(), context)

    tool_uses = Enum.filter(resp.message.content, &match?(%ToolUse{}, &1))
    assert length(tool_uses) > 0
    tool_use = hd(tool_uses)

    IO.puts(
      "[openrouter] tool: #{tool_use.name}(#{inspect(tool_use.input)}) (stop: #{resp.stop_reason})"
    )
  end

  test "thinking" do
    assert {:ok, %Response{} = resp} =
             Omni.generate_text(reasoning_model(), "How many R's are in strawberry?",
               thinking: :high
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

    IO.puts("[openrouter] thinking: \"#{truncated}\" (#{String.length(thinking_text)} chars)")
    IO.puts("[openrouter] answer: \"#{String.replace(answer, "\n", " ")}\"")
  end
end
