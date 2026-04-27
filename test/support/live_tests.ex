defmodule LiveTests do
  @moduledoc false

  import ExUnit.Assertions

  alias Omni.{Context, Message, Response, Schema}
  alias Omni.Content.{Attachment, Text, Thinking, ToolUse}

  @logo_file "test/support/fixtures/files/logo.png"
  @pdf_file "test/support/fixtures/files/whitepaper.pdf"

  def text_generation(model, opts \\ []) do
    {model, label} = resolve(model)

    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model, "Write a haiku about the sky.", opts)

    assert resp.stop_reason in [:stop, :length]
    texts = filter(resp, Text)
    assert length(texts) > 0
    text = hd(texts).text
    assert is_binary(text) and text != ""

    IO.puts(
      "[#{label}] text: \"#{truncate(text, 80)}\" " <>
        "(stop: #{resp.stop_reason}, in: #{resp.usage.input_tokens}, out: #{resp.usage.output_tokens})"
    )
  end

  def thinking(model, opts \\ []) do
    {model, label} = resolve(model)
    opts = Keyword.put_new(opts, :thinking, :low)

    assert {:ok, %Response{} = resp} =
             Omni.generate_text(model, "What is the tallest building in Swindon?", opts)

    assert resp.stop_reason in [:stop, :length]

    thinking_blocks = filter(resp, Thinking)
    texts = filter(resp, Text)
    assert length(texts) > 0
    answer = hd(texts).text

    has_thinking_text = thinking_blocks != [] and hd(thinking_blocks).text not in [nil, ""]
    has_thought_signature = Enum.any?(texts, &(&1.signature != nil))

    cond do
      has_thinking_text ->
        thinking_text = hd(thinking_blocks).text

        IO.puts(
          "[#{label}] thinking: \"#{truncate(thinking_text, 200)}\" (#{String.length(thinking_text)} chars)"
        )

      has_thought_signature ->
        IO.puts("[#{label}] thinking: (signature only)")

      true ->
        IO.puts("[#{label}] thinking: (none)")
    end

    IO.puts("[#{label}] answer: \"#{oneline(answer)}\"")
  end

  def tool_use(model, opts \\ []) do
    {model, label} = resolve(model)

    tool =
      Omni.tool(
        name: "get_weather",
        description: "Gets the current weather for a city",
        input_schema: %{
          type: "object",
          properties: %{city: %{type: "string"}},
          required: ["city"]
        }
      )

    context =
      Context.new(
        messages: [Message.new("What is the weather in London?")],
        tools: [tool]
      )

    assert {:ok, %Response{} = resp} = Omni.generate_text(model, context, opts)

    tool_uses = filter(resp, ToolUse)
    assert length(tool_uses) > 0
    tool_use_block = hd(tool_uses)

    IO.puts(
      "[#{label}] tool: #{tool_use_block.name}(#{inspect(tool_use_block.input)}) (stop: #{resp.stop_reason})"
    )
  end

  def structured_output(model, opts \\ []) do
    {model, label} = resolve(model)

    schema =
      Schema.object(
        %{
          name: Schema.string(),
          color: Schema.string()
        },
        required: [:name, :color]
      )

    opts = Keyword.put(opts, :output, schema)

    assert {:ok, %Response{} = resp} =
             Omni.generate_text(
               model,
               "What color is the sky? Respond with name 'sky' and its color.",
               opts
             )

    assert resp.stop_reason == :stop
    assert is_map(resp.output)
    assert Map.has_key?(resp.output, :name)
    assert Map.has_key?(resp.output, :color)

    IO.puts("[#{label}] output: #{inspect(resp.output)}")
  end

  def vision_image(model, opts \\ []) do
    {model, label} = resolve(model)

    image_data = File.read!(@logo_file)
    base64 = Base.encode64(image_data)

    message =
      Message.new(
        role: :user,
        content: [
          Text.new(text: "What brand logo is this? Reply with just the brand name."),
          Attachment.new(source: {:base64, base64}, media_type: "image/png")
        ]
      )

    context = Context.new(messages: [message])

    assert {:ok, %Response{} = resp} = Omni.generate_text(model, context, opts)

    assert resp.stop_reason in [:stop, :length]
    texts = filter(resp, Text)
    assert length(texts) > 0
    answer = hd(texts).text
    assert is_binary(answer) and answer != ""

    IO.puts("[#{label}] image: \"#{oneline(answer)}\"")
  end

  def vision_pdf(model, opts \\ []) do
    {model, label} = resolve(model)

    pdf_data = File.read!(@pdf_file)
    base64 = Base.encode64(pdf_data)

    message =
      Message.new(
        role: :user,
        content: [
          Text.new(text: "Who authored this document? Reply with just the author name."),
          Attachment.new(source: {:base64, base64}, media_type: "application/pdf")
        ]
      )

    context = Context.new(messages: [message])

    assert {:ok, %Response{} = resp} = Omni.generate_text(model, context, opts)

    assert resp.stop_reason in [:stop, :length]
    texts = filter(resp, Text)
    assert length(texts) > 0
    answer = hd(texts).text
    assert is_binary(answer) and answer != ""

    IO.puts("[#{label}] pdf: \"#{oneline(answer)}\"")
  end

  def roundtrip(model, opts \\ []) do
    {model, label} = resolve(model)
    opts = Keyword.put_new(opts, :thinking, :low)

    # Turn 1: generate with thinking to produce signatures
    assert {:ok, %Response{} = resp1} =
             Omni.generate_text(model, "What is 23 + 45?", opts)

    assert resp1.stop_reason in [:stop, :length]

    block_types =
      Enum.map(resp1.message.content, fn
        %Thinking{} -> :thinking
        %Text{} -> :text
        other -> other.__struct__
      end)

    # Turn 2: feed the response back with a follow-up question
    messages = [
      Message.new("What is 23 + 45?"),
      resp1.message,
      Message.new("Now multiply that result by 2.")
    ]

    context = Context.new(messages: messages)

    assert {:ok, %Response{} = resp2} = Omni.generate_text(model, context, opts)

    assert resp2.stop_reason in [:stop, :length]
    texts = filter(resp2, Text)
    assert length(texts) > 0
    answer = hd(texts).text
    assert is_binary(answer) and answer != ""

    IO.puts(
      "[#{label}] roundtrip: turn 1 blocks=#{inspect(block_types)}, " <>
        "turn 2: \"#{truncate(answer, 80)}\""
    )
  end

  # -- Private helpers --

  defp resolve({provider_id, model_id}) do
    {:ok, model} = Omni.get_model(provider_id, model_id)
    {model, "#{provider_id}:#{model_id}"}
  end

  defp resolve(%Omni.Model{} = model) do
    {model, model.id}
  end

  defp filter(%Response{} = resp, type) do
    Enum.filter(resp.message.content, &is_struct(&1, type))
  end

  defp truncate(text, max) do
    text = oneline(text)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "...", else: text
  end

  defp oneline(text), do: String.replace(text, "\n", " ")
end
