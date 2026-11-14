defmodule Omni.Verify.Scenarios do
  @moduledoc false

  # One function per verification scenario. Each returns `{:pass, summary}`,
  # `{:fail, reason}`, or `{:fail, reason, error}` when there is detail behind
  # the reason. Reasons are generic (`HTTP 429`, `no thinking`) and never carry
  # provider text, so they are safe to save; the detail goes to the terminal.

  alias Omni.{Answer, Context, Decision, Message, Response, Schema}
  alias Omni.Content.{Attachment, Text, Thinking, ToolResult, ToolUse}

  @thinking_prompt "How many times does the letter 'r' appear in the phrase " <>
                     "'strawberry rhubarb raspberry'? Count carefully, word by word."

  @cache_pause 2_000

  @doc "Runs one scenario."
  @spec run(atom(), Omni.Model.t(), keyword()) ::
          {:pass, String.t()} | {:fail, String.t(), String.t() | nil}
  def run(scenario, model, opts) do
    case apply(__MODULE__, scenario, [model, opts]) do
      {:fail, reason} -> {:fail, reason, nil}
      outcome -> outcome
    end
  end

  @doc """
  Returns the request a scenario sends.

  That is its context (a decision for the decision scenarios) and the options
  it adds. Capture scripts record these, so fixtures are recordings of what
  verify checks. `:kitchen_sink` and `:cache_usage` give turn 1; `follow_up/3`
  builds the cache scenario's turn 2.
  """
  @spec request(atom()) :: {Context.t() | Decision.t(), keyword()}
  def request(:text), do: {Context.new("Write a haiku about the sky."), [thinking: false]}

  def request(:thinking), do: {Context.new(@thinking_prompt), [thinking: :low]}

  def request(:no_thinking), do: {Context.new(@thinking_prompt), [thinking: false]}

  def request(:tool_use) do
    context =
      Context.new(
        messages: [Message.new("What is the weather in London right now?")],
        tools: [weather_tool(nil)]
      )

    {context, []}
  end

  def request(:structured_output) do
    context = Context.new("What color is the sky? Respond with name 'sky' and its color.")

    schema =
      Schema.object(%{name: Schema.string(), color: Schema.string()}, required: [:name, :color])

    {context, [output: schema]}
  end

  def request(:kitchen_sink) do
    question = Message.new("What's the current time and weather in London and New York?")
    tools = [time_tool(), weather_tool(&weather/1)]
    {Context.new(messages: [question], tools: tools), [thinking: :low]}
  end

  def request(:cache_usage) do
    question = Message.new("Which station has the code #{station_code(42)}? Reply with its name.")
    {Context.new(system: cache_filler(), messages: [question]), [cache: :short]}
  end

  # Questions with one clear answer, so a pass can check the answers mean
  # something: a crossed key or an off-by-one level fails, a weak model doesn't.
  def request(:decision) do
    decision =
      Decision.new(
        {"I was charged twice for my subscription this month. Please refund the extra charge.",
         [
           refund:
             Omni.predicate("Is the customer asking for a refund?",
               true: "Asks for money back",
               false: "Asks for anything else"
             ),
           team:
             Omni.choice("Which team should handle this?",
               billing: "Charges, invoices and refunds",
               infra: "Outages and downtime",
               other: nil
             ),
           urgency: Omni.score("How urgent is this?", [:low, :medium, :high])
         ]}
      )

    {decision, []}
  end

  def request(:decision_json) do
    state = %{
      "ticket" => %{
        "subject" => "Site down",
        "body" => "Nobody on our team can log in, the dashboard returns a 502.",
        "plan" => "enterprise"
      }
    }

    decision =
      Decision.new(
        {state,
         [
           outage:
             Omni.predicate(%{
               "question" => "Does the ticket report an outage?",
               "field" => "ticket.body"
             }),
           team: Omni.choice("Which team should handle this?", [:billing, :infra, :other])
         ]}
      )

    {decision, []}
  end

  @doc "Turn 2 of a two-turn scenario, built from turn 1's context and response."
  @spec follow_up(atom(), Context.t(), Response.t()) :: Context.t()
  def follow_up(:cache_usage, %Context{} = context, %Response{} = resp) do
    %{
      context
      | messages: context.messages ++ [resp.message, Message.new("What is its elevation?")]
    }
  end

  @doc false
  def text(model, opts) do
    {context, opts} = request(:text, opts)

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :stop),
         {:ok, text} <- text_of(resp) do
      {:pass, excerpt(text)}
    end
  end

  @doc false
  def thinking(model, opts) do
    {context, opts} = request(:thinking, opts)

    with {:ok, resp} <- generate(model, context, opts),
         {:ok, text} <- text_of(resp),
         {:ok, thinking} <- thinking_of(resp) do
      {:pass, "#{thinking} → #{excerpt(text, 40)}"}
    end
  end

  @doc false
  def no_thinking(model, opts) do
    {context, opts} = request(:no_thinking, opts)

    with {:ok, resp} <- generate(model, context, opts),
         {:ok, text} <- text_of(resp),
         :ok <- check(blocks(resp, Thinking) == [], "thinking blocks present") do
      {:pass, excerpt(text)}
    end
  end

  @doc false
  def tool_use(model, opts) do
    {context, opts} = request(:tool_use, opts)

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :tool_use),
         {:ok, tool_use} <- find_tool_use(resp, "get_weather"),
         :ok <- check(inspect(tool_use.input) =~ ~r/london/i, "input doesn't mention London") do
      {:pass, "get_weather(#{inspect(tool_use.input)})"}
    end
  end

  @doc false
  def structured_output(model, opts) do
    {context, opts} = request(:structured_output, opts)

    with {:ok, resp} <- generate(model, context, opts),
         :ok <- stop_reason(resp, :stop),
         :ok <- check(is_map(resp.output), "no output"),
         :ok <- check(is_binary(resp.output[:name]), "output has no string name"),
         :ok <- check(is_binary(resp.output[:color]), "output has no string color") do
      {:pass, inspect(resp.output)}
    end
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
    {turn1, opts} = request(:kitchen_sink, opts)

    with {:ok, resp1} <- generate(model, turn1, opts),
         :ok <- stop_reason(resp1, :stop),
         :ok <- check(tool_rounds(resp1) > 0, "no tools were run"),
         {:ok, _text} <- text_of(resp1),
         follow_up = turn1.messages ++ resp1.messages ++ [Message.new("Which city is warmer?")],
         turn2 = %{turn1 | messages: follow_up},
         {:ok, resp2} <- generate(model, turn2, opts),
         :ok <- stop_reason(resp2, :stop),
         {:ok, text} <- text_of(resp2) do
      {:pass, "#{tool_rounds(resp1)} tool round(s) → #{excerpt(text, 50)}"}
    end
  end

  @doc false
  def cache_usage(model, opts) do
    {turn1, opts} = request(:cache_usage, opts)

    with {:ok, resp1} <- generate(model, turn1, opts),
         :ok <- Process.sleep(@cache_pause),
         turn2 = follow_up(:cache_usage, turn1, resp1),
         {:ok, resp2} <- generate(model, turn2, opts),
         :ok <-
           check(
             resp2.usage.cache_read_tokens > 0,
             "no cache read on turn 2 (#{resp2.usage.input_tokens} input tokens)"
           ) do
      {:pass,
       "turn 1 wrote #{resp1.usage.cache_write_tokens}, " <>
         "turn 2 read #{resp2.usage.cache_read_tokens} of #{resp2.usage.input_tokens}"}
    end
  end

  @doc false
  def decision(model, opts), do: run_decision(:decision, model, opts)

  @doc false
  def decision_json(model, opts), do: run_decision(:decision_json, model, opts)

  @doc """
  Checks an answered decision scenario.

  Every answer must be present and well formed (no refusal, probabilities and
  confidences floats from 0 to 1, keyed by the question's options in order,
  input tokens counted), and the clear-cut questions answered as expected.
  The score is checked for shape only. The integration tests' baseline calls
  this too, to hold fixtures to the same rule.
  """
  @spec check_decision(atom(), Decision.t()) :: :ok | {:fail, String.t()}
  def check_decision(scenario, %Decision{} = decision) do
    with :ok <- check(decision.usage.input_tokens > 0, "no input tokens"),
         :ok <- check_answers(decision) do
      check_meaning(scenario, Map.new(decision.answers))
    end
  end

  defp check_answers(%Decision{questions: questions, answers: answers}) do
    Enum.zip(questions, answers)
    |> Enum.reduce_while(:ok, fn {{name, question}, {name, answer}}, :ok ->
      case check_answer(question, answer) do
        :ok -> {:cont, :ok}
        {:fail, reason} -> {:halt, {:fail, "#{name}: #{reason}"}}
      end
    end)
  end

  defp check_answer(_question, %Answer.Refusal{}), do: {:fail, "refused"}

  defp check_answer(_question, %Answer.Predicate{probability: p}),
    do: check(probability?(p), "probability #{inspect(p)}")

  defp check_answer(%{choices: options}, %Answer.Choice{} = answer) do
    with :ok <- check(Enum.any?(options, &(elem(&1, 0) == answer.choice)), "unknown choice"),
         :ok <- check_probabilities(options, answer.probabilities) do
      check_confidence(answer.confidence)
    end
  end

  defp check_answer(%{levels: options}, %Answer.Score{} = answer) do
    with :ok <-
           check(
             is_float(answer.score) and answer.score >= 0 and answer.score <= length(options) - 1,
             "score #{inspect(answer.score)}"
           ),
         :ok <- check_probabilities(options, answer.probabilities) do
      check_confidence(answer.confidence)
    end
  end

  defp check_probabilities(options, probabilities) do
    with :ok <-
           check(
             Enum.map(probabilities, &elem(&1, 0)) == Enum.map(options, &elem(&1, 0)),
             "probabilities don't match the options"
           ) do
      check(Enum.all?(probabilities, &probability?(elem(&1, 1))), "probability out of range")
    end
  end

  defp check_confidence(nil), do: :ok
  defp check_confidence(c), do: check(probability?(c), "confidence #{inspect(c)}")

  defp probability?(p), do: is_float(p) and p >= 0 and p <= 1

  defp check_meaning(:decision, answers) do
    with :ok <- expect_yes(answers.refund, :refund) do
      expect_choice(answers.team, :team, :billing)
    end
  end

  defp check_meaning(:decision_json, answers) do
    with :ok <- expect_yes(answers.outage, :outage) do
      expect_choice(answers.team, :team, :infra)
    end
  end

  defp expect_yes(%Answer.Predicate{probability: p}, name),
    do: check(p > 0.5, "#{name} is #{Float.round(p, 2)}, expected over 0.5")

  defp expect_choice(%Answer.Choice{choice: choice}, name, expected),
    do: check(choice == expected, "#{name} is #{inspect(choice)}, expected #{inspect(expected)}")

  defp run_decision(scenario, model, opts) do
    {decision, opts} = request(scenario, opts)

    with {:ok, decision} <- decide(model, decision, opts),
         :ok <- check_decision(scenario, decision) do
      {:pass, decision_summary(decision)}
    end
  end

  defp decide(model, decision, opts) do
    case Omni.decide(model, decision, opts) do
      {:ok, %Decision{} = decision} -> {:ok, decision}
      {:error, reason} -> {:fail, error_reason(reason), inspect(reason, pretty: true)}
    end
  end

  defp decision_summary(%Decision{answers: answers}) do
    Enum.map_join(answers, " · ", fn
      {name, %Answer.Predicate{probability: p}} -> "#{name} #{Float.round(p, 2)}"
      {name, %Answer.Choice{choice: choice}} -> "#{name} #{choice}"
      {name, %Answer.Score{score: score}} -> "#{name} #{Float.round(score, 2)}"
    end)
  end

  # -- Shared --

  # The scenario's options win over the caller's.
  defp request(scenario, opts) do
    {context, scenario_opts} = request(scenario)
    {context, Keyword.merge(opts, scenario_opts)}
  end

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
  end

  defp generate(model, context, opts) do
    case Omni.generate_text(model, context, opts) do
      {:ok, %Response{} = resp} -> {:ok, resp}
      {:error, reason} -> {:fail, error_reason(reason), inspect(reason, pretty: true)}
    end
  end

  defp error_reason({:http_error, status, _body}), do: "HTTP #{status}"
  defp error_reason({:stream_error, _}), do: "stream error"
  defp error_reason(:incomplete_stream), do: "incomplete stream"
  defp error_reason(%Req.TransportError{reason: reason}), do: "transport error (#{reason})"
  defp error_reason({:unsupported_capability, cap}), do: "no #{cap} capability"
  defp error_reason({:invalid_answer, _name}), do: "invalid answer"
  defp error_reason({:invalid_response, _body}), do: "invalid response"
  defp error_reason(_reason), do: "request failed"

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:fail, reason}

  defp stop_reason(%Response{stop_reason: expected}, expected), do: :ok

  defp stop_reason(%Response{stop_reason: other, error: error}, expected) do
    {:fail, "stop reason #{inspect(other)}, expected #{inspect(expected)}",
     error && inspect(error, pretty: true)}
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

  # Thinking text, a signature, redacted data, a thought signature on text
  # (Gemini), or encrypted reasoning details (Gemini through OpenRouter) all
  # count. Adaptive models may skip reasoning on an easy prompt, so this shows
  # thinking was switched on, not that the model used it. Public for the
  # integration tests' baseline, which holds fixtures to the same rule.
  @doc false
  def thinking_of(resp) do
    thinking = blocks(resp, Thinking)
    signed_text? = Enum.any?(blocks(resp, Text), &(&1.signature not in [nil, ""]))
    details? = resp.message != nil and resp.message.private[:reasoning_details] not in [nil, []]

    cond do
      text = Enum.find_value(thinking, &(&1.text not in [nil, ""] and &1.text)) ->
        {:ok, "thought #{String.length(text)} chars"}

      Enum.any?(thinking, &(&1.signature not in [nil, ""] or &1.redacted_data != nil)) ->
        {:ok, "thinking (signature only)"}

      signed_text? ->
        {:ok, "thought signature on text"}

      details? ->
        {:ok, "reasoning details only"}

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
