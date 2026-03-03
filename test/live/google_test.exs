defmodule Live.GoogleTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Message, Response}
  alias Omni.Content.{Text, Thinking, ToolUse}

  defp model do
    {:ok, model} = Omni.get_model(:google, "gemini-2.5-flash")
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
      "[google] text: \"#{truncated}\" (stop: #{resp.stop_reason}, in: #{resp.usage.input_tokens}, out: #{resp.usage.output_tokens})"
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

    # Google may return text instead of tool use depending on model behavior
    assert length(resp.message.content) > 0
    assert resp.message.role == :assistant

    case Enum.filter(resp.message.content, &match?(%ToolUse{}, &1)) do
      [tool_use | _] ->
        IO.puts(
          "[google] tool: #{tool_use.name}(#{inspect(tool_use.input)}) (stop: #{resp.stop_reason})"
        )

      [] ->
        text = Enum.find(resp.message.content, &match?(%Text{}, &1))
        truncated = String.slice(text.text, 0, 80)
        IO.puts("[google] tool (text fallback): \"#{truncated}\" (stop: #{resp.stop_reason})")
    end
  end

  test "thinking" do
    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model(), "How many R's are in strawberry?", thinking: :high)

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

    IO.puts("[google] thinking: \"#{truncated}\" (#{String.length(thinking_text)} chars)")
    IO.puts("[google] answer: \"#{String.replace(answer, "\n", " ")}\"")
  end
end
