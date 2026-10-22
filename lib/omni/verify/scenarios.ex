defmodule Omni.Verify.Scenarios do
  @moduledoc false

  # One function per verification scenario. Each returns `{:pass, summary}` or
  # `{:fail, reason, request_body}`, where the request body is the JSON Omni
  # sends for the failing call (nil when it can't be built).

  alias Omni.{Context, Message, Request, Response, Schema}
  alias Omni.Content.{Attachment, Text, Thinking, ToolResult, ToolUse}

  @thinking_prompt "How many times does the letter 'r' appear in the phrase " <>
                     "'strawberry rhubarb raspberry'? Count carefully, word by word."

  @cache_pause 2_000

  @doc "Runs one scenario."
  @spec run(atom(), Omni.Model.t(), keyword()) ::
          {:pass, String.t()} | {:fail, String.t(), map() | nil}
  def run(scenario, model, opts), do: apply(__MODULE__, scenario, [model, opts])

  @doc false
  def text(model, opts) do
    context = Context.new("Write a haiku about the sky.")

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :stop),
         {:ok, text} <- text_of(resp) do
      {:pass, excerpt(text)}
    end
    |> finish(model, context, opts)
  end

  @doc false
  def thinking(model, opts) do
    context = Context.new(@thinking_prompt)
    opts = Keyword.put(opts, :thinking, :low)

    with {:ok, resp} <- generate(model, context, opts),
         {:ok, text} <- text_of(resp),
         {:ok, thinking} <- thinking_of(resp) do
      {:pass, "#{thinking} → #{excerpt(text, 40)}"}
    end
    |> finish(model, context, opts)
  end

  @doc false
  def no_thinking(model, opts) do
    context = Context.new(@thinking_prompt)
    opts = Keyword.put(opts, :thinking, false)

    with {:ok, resp} <- generate(model, context, opts),
         {:ok, text} <- text_of(resp),
         :ok <- check(blocks(resp, Thinking) == [], "thinking blocks present") do
      {:pass, excerpt(text)}
    end
    |> finish(model, context, opts)
  end

  @doc false
  def tool_use(model, opts) do
    context =
      Context.new(
        messages: [Message.new("What is the weather in London right now?")],
        tools: [weather_tool(nil)]
      )

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :tool_use),
         {:ok, tool_use} <- find_tool_use(resp, "get_weather"),
         :ok <- check(inspect(tool_use.input) =~ ~r/london/i, "input doesn't mention London") do
      {:pass, "get_weather(#{inspect(tool_use.input)})"}
    end
    |> finish(model, context, opts)
  end

  @doc false
  def structured_output(model, opts) do
    context = Context.new("What color is the sky? Respond with name 'sky' and its color.")

    schema =
      Schema.object(%{name: Schema.string(), color: Schema.string()}, required: [:name, :color])

    opts = Keyword.put(opts, :output, schema)

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :stop),
         :ok <- check(is_map(resp.output), "no output"),
         :ok <- check(is_binary(resp.output[:name]), "output has no string name"),
         :ok <- check(is_binary(resp.output[:color]), "output has no string color") do
      {:pass, inspect(resp.output)}
    end
    |> finish(model, context, opts)
  end

  @doc false
  def image(model, opts) do
    attachment(
      model,
      opts,
      "logo.png",
      "image/png",
      "What brand logo is this? Reply with just the brand name.",
      ~r/nike/i
    )
  end

  @doc false
  def pdf(model, opts) do
    attachment(
      model,
      opts,
      "whitepaper.pdf",
      "application/pdf",
      "Who authored this document? Reply with just the author name.",
      ~r/nakamoto/i
    )
  end

  @doc false
  def kitchen_sink(model, opts) do
    tools = [time_tool(), weather_tool(&weather/1)]
    opts = Keyword.put(opts, :thinking, :low)
    question = Message.new("What's the current time and weather in London and New York?")
    turn1 = Context.new(messages: [question], tools: tools)

    with {:ok, resp1} <- generate(model, turn1, opts),
         :ok <- stop_reason(resp1, :stop),
         :ok <- check(tool_rounds(resp1) > 0, "no tools were run"),
         {:ok, _text} <- text_of(resp1) do
      turn2 =
        Context.new(
          messages: [question | resp1.messages] ++ [Message.new("Which city is warmer?")],
          tools: tools
        )

      with {:ok, resp2} <- generate(model, turn2, opts),
           :ok <- stop_reason(resp2, :stop),
           {:ok, text} <- text_of(resp2) do
        {:pass, "#{tool_rounds(resp1)} tool round(s) → #{excerpt(text, 50)}"}
      end
      |> finish(model, turn2, opts)
    end
    |> finish(model, turn1, opts)
  end

  @doc false
  def cache_usage(model, opts) do
    opts = Keyword.put(opts, :cache, :short)
    system = cache_filler()
    question = Message.new("Which station has the code #{station_code(42)}? Reply with its name.")
    turn1 = Context.new(system: system, messages: [question])

    with {:ok, resp1} <- generate(model, turn1, opts) do
      Process.sleep(@cache_pause)

      turn2 =
        Context.new(
          system: system,
          messages: [question, resp1.message, Message.new("What is its elevation?")]
        )

      with {:ok, resp2} <- generate(model, turn2, opts),
           :ok <-
             check(
               resp2.usage.cache_read_tokens > 0,
               "no cache read on turn 2 (#{resp2.usage.input_tokens} input tokens)"
             ) do
        {:pass,
         "turn 1 wrote #{resp1.usage.cache_write_tokens}, " <>
           "turn 2 read #{resp2.usage.cache_read_tokens} of #{resp2.usage.input_tokens}"}
      end
      |> finish(model, turn2, opts)
    end
    |> finish(model, turn1, opts)
  end

  # -- Shared --

  defp attachment(model, opts, file, media_type, prompt, expected) do
    data = :omni |> Application.app_dir(Path.join("priv/verify", file)) |> File.read!()

    context =
      Context.new([
        Message.new(
          role: :user,
          content: [
            Text.new(text: prompt),
            Attachment.new(source: {:base64, Base.encode64(data)}, media_type: media_type)
          ]
        )
      ])

    with {:ok, resp} <- generate(model, context, opts),
         {:ok, text} <- text_of(resp),
         :ok <- check(text =~ expected, "unexpected answer: #{excerpt(text)}") do
      {:pass, excerpt(text)}
    end
    |> finish(model, context, opts)
  end

  defp generate(model, context, opts) do
    case Omni.generate_text(model, context, opts) do
      {:ok, %Response{} = resp} -> {:ok, resp}
      {:error, reason} -> {:fail, "error: " <> excerpt(inspect(reason), 300)}
    end
  end

  # Passes results through; turns a bare failure into one carrying the
  # request body of the call that failed. An inner turn's failure arrives
  # already complete, so the outer `finish` leaves it alone.
  defp finish({:fail, reason}, model, context, opts),
    do: {:fail, reason, request_body(model, context, opts)}

  defp finish(result, _model, _context, _opts), do: result

  # A placeholder key lets the body build when the real key is the problem;
  # auth only touches headers, never the body.
  defp request_body(model, context, opts) do
    case Request.build(model, context, Keyword.put(opts, :api_key, "verify")) do
      {:ok, req} -> req.options[:json]
      {:error, _} -> nil
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:fail, reason}

  defp stop_reason(%Response{stop_reason: expected}, expected), do: :ok

  defp stop_reason(%Response{stop_reason: other, error: error}, expected) do
    detail = if error, do: " (#{excerpt(inspect(error), 200)})", else: ""
    {:fail, "stop reason #{inspect(other)}, expected #{inspect(expected)}#{detail}"}
  end

  defp blocks(%Response{message: nil}, _type), do: []

  defp blocks(%Response{message: message}, type),
    do: Enum.filter(message.content, &is_struct(&1, type))

  defp text_of(resp) do
    case resp |> blocks(Text) |> Enum.map_join(& &1.text) |> String.trim() do
      "" -> {:fail, "no text"}
      text -> {:ok, text}
    end
  end

  # Thinking text, a signature, redacted data, or a thought signature on text
  # (Gemini) all count as evidence the model reasoned.
  defp thinking_of(resp) do
    thinking = blocks(resp, Thinking)
    signed_text? = Enum.any?(blocks(resp, Text), &(&1.signature not in [nil, ""]))

    cond do
      text = Enum.find_value(thinking, &(&1.text not in [nil, ""] and &1.text)) ->
        {:ok, "thought #{String.length(text)} chars"}

      Enum.any?(thinking, &(&1.signature not in [nil, ""] or &1.redacted_data != nil)) ->
        {:ok, "thinking (signature only)"}

      signed_text? ->
        {:ok, "thought signature on text"}

      true ->
        {:fail, "no thinking"}
    end
  end

  defp find_tool_use(resp, name) do
    case Enum.find(blocks(resp, ToolUse), &(&1.name == name)) do
      nil -> {:fail, "no #{name} tool use"}
      tool_use -> {:ok, tool_use}
    end
  end

  defp tool_rounds(%Response{messages: messages}) do
    Enum.count(messages, fn message ->
      message.role == :user and Enum.any?(message.content, &is_struct(&1, ToolResult))
    end)
  end

  defp excerpt(text, max \\ 80) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # -- Tools --

  defp weather_tool(handler) do
    Omni.tool(
      name: "get_weather",
      description: "Gets the current weather for a city",
      input_schema: %{
        type: "object",
        properties: %{city: %{type: "string", description: "City name"}},
        required: ["city"]
      },
      handler: handler
    )
  end

  defp time_tool do
    Omni.tool(
      name: "get_time",
      description: "Gets the current local time for a city",
      input_schema: %{
        type: "object",
        properties: %{city: %{type: "string", description: "City name"}},
        required: ["city"]
      },
      handler: &time/1
    )
  end

  defp weather(input) do
    lookup(input, %{
      "london" => "Cloudy with light drizzle, around 8°C.",
      "new york" => "Partly sunny, cold and breezy, around 2°C."
    })
  end

  defp time(input), do: lookup(input, %{"london" => "17:28", "new york" => "12:28"})

  defp lookup(input, table) do
    city = (input[:city] || input["city"] || "") |> to_string() |> String.downcase()

    Enum.find_value(table, "No data for that city.", fn {name, value} ->
      String.contains?(city, name) && value
    end)
  end

  # -- Cache filler --

  # A deterministic reference table of about 7k tokens: above every
  # provider's minimum cacheable prompt, and real data to ask about.
  @prefixes ~w(Alder Birch Cedar Dun Elm Fern Glen Hazel Ivy Juniper Kings Larch Marsh North Oak Pine)
  @suffixes ~w(Cross Bridge Hill Vale Heath Moor Green Field Ford Wood Lea Park)

  defp cache_filler do
    rows =
      for n <- 1..200 do
        name =
          "#{Enum.at(@prefixes, rem(n, 16))} #{Enum.at(@suffixes, rem(div(n, 16), 12))} #{n}"

        "| #{n} | #{name} | #{station_code(n)} | #{rem(n * 37, 900) + 20} m | " <>
          "#{rem(n, 6) + 1} | #{1850 + rem(n * 13, 150)} |"
      end

    """
    You are a railway reference assistant. Answer questions using only the
    station table below.

    | No. | Station | Code | Elevation | Platforms | Opened |
    |---|---|---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  defp station_code(n) do
    letters = for i <- 0..1, do: <<?A + rem(n * (7 + i * 11), 26)>>
    "#{letters}-#{rem(n * 7919, 9000) + 1000}"
  end
end
