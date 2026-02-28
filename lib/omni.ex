defmodule Omni do
  @moduledoc """
  Unified Elixir client for LLM APIs across multiple providers.

  Omni provides a single API for text generation that works with Anthropic,
  OpenAI, Google Gemini, and OpenRouter. All requests are streaming-first —
  `generate_text/3` is built on top of `stream_text/3`.

  ## Setup

  Add Omni to your dependencies:

      {:omni, "~> 1.0"}

  Configure your provider API keys:

      # config/runtime.exs
      config :omni, Omni.Providers.Anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
      config :omni, Omni.Providers.OpenAI, api_key: System.get_env("OPENAI_API_KEY")

  Anthropic, OpenAI, and Google are loaded by default. To add others or limit
  what loads at startup:

      config :omni, :providers, [:anthropic, :openai, :openrouter]

  You can also pass `:api_key` directly to `generate_text/3` or `stream_text/3`.

  ## Generating text

  The simplest way to use Omni — pass a model tuple and a string:

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

      response.message
      #=> %Omni.Message{role: :assistant, content: [%Omni.Content.Text{text: "Hello! How can..."}]}

      response.usage
      #=> %Omni.Usage{input_tokens: 10, output_tokens: 25, total_cost: 0.0003, ...}

  For multi-turn conversations, build a context with a system prompt and messages:

      context = Omni.context(
        system: "You are a helpful assistant.",
        messages: [
          Omni.message(role: :user, content: "What is Elixir?"),
          Omni.message(role: :assistant, content: "Elixir is a functional programming language..."),
          Omni.message(role: :user, content: "How does it handle concurrency?")
        ]
      )

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, context)

  ## Streaming

  `stream_text/3` returns a `StreamingResponse` that you can consume with
  event handlers:

      {:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Tell me a story")

      {:ok, response} =
        stream
        |> StreamingResponse.on(:text_delta, fn %{delta: text} -> IO.write(text) end)
        |> StreamingResponse.complete()

  For simple cases where you just need the text chunks:

      stream
      |> StreamingResponse.text_stream()
      |> Enum.each(&IO.write/1)

  See `Omni.StreamingResponse` for the full event taxonomy.

  ## Structured output

  Pass an `Omni.Schema` map via the `:output` option to get validated,
  decoded output:

      schema = Omni.Schema.object(%{
        name: Omni.Schema.string(description: "The capital city"),
        population: Omni.Schema.integer(description: "Approximate population")
      }, required: [:name, :population])

      {:ok, response} =
        Omni.generate_text(
          {:anthropic, "claude-sonnet-4-5-20250514"},
          "What is the capital of France?",
          output: schema
        )

      response.output
      #=> %{name: "Paris", population: 2161000}

  The schema is sent to the provider for constrained decoding. The response
  text is validated against the schema and decoded into `response.output`,
  with automatic retries on validation failure.

  ## Tools

  Define inline tools with `Omni.tool/1`:

      weather_tool = Omni.tool(
        name: "get_weather",
        description: "Gets the current weather for a city",
        input_schema: Omni.Schema.object(
          %{city: Omni.Schema.string(description: "City name")},
          required: [:city]
        ),
        handler: fn input -> "72°F and sunny in \#{input.city}" end
      )

      context = Omni.context(
        messages: [Omni.message("What's the weather in London?")],
        tools: [weather_tool]
      )

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-4-5-20250514"}, context)

  When tools have handlers, the loop automatically executes tool uses and feeds
  results back to the model until it produces a final text response.

  For reusable tools with validation, define a tool module — see `Omni.Tool`.

  ## Agents

  For stateful, multi-turn conversations, `Omni.Agent` wraps the generation
  loop in a GenServer with lifecycle callbacks:

      {:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-sonnet-4-5-20250514"})
      :ok = Omni.Agent.prompt(agent, "Hello!")

  The calling process receives `{:agent, pid, type, data}` messages as the
  agent streams its response. See `Omni.Agent` for the full callback API,
  event types, and tool approval workflows.

  ## Providers

  Omni ships with built-in providers for Anthropic, OpenAI, Google, and
  OpenRouter. Each provider is paired with a dialect that handles wire format
  translation.

  Models are referenced as `{provider_id, model_id}` tuples. To list available
  models for a provider:

      {:ok, models} = Omni.list_models(:anthropic)

  To add a custom provider, implement the `Omni.Provider` behaviour and load
  it at runtime — see `Omni.Provider` for details.
  """

  alias Omni.{Context, Loop, Model, Response, StreamingResponse}

  @doc group: :generation
  @doc """
  Streams a text generation request, returning a `%StreamingResponse{}`.

  The model can be a `%Model{}` struct or a `{provider_id, model_id}` tuple.
  The context can be a string, list of messages, or `%Context{}` struct.

  When tools with handlers are present in the context, automatically executes
  tool uses and loops until the model stops calling tools. Between rounds,
  synthetic `:tool_result` events are emitted for observability.

  ## Options

    * `:max_tokens` — maximum output tokens (Anthropic defaults to 4096)
    * `:temperature` — sampling temperature (number)
    * `:thinking` — enable extended thinking. Pass `true`, a budget level
      (`:low`, `:medium`, `:high`, `:max`), or `%{effort: level, budget: tokens}`
    * `:output` — a JSON Schema map for structured output (see the
      [Structured output](#module-structured-output) section above)
    * `:max_steps` — maximum tool execution rounds (default `:infinity`).
      Pass `1` to disable auto-looping for manual tool handling
    * `:cache` — prompt caching strategy (`:short` or `:long`)
    * `:timeout` — request timeout in milliseconds (default `300_000`)
    * `:api_key` — API key, overriding provider/app config
    * `:raw` — when `true`, attaches raw `{%Req.Request{}, %Req.Response{}}` tuples
      to the response (one per round)
    * `:metadata` — arbitrary metadata map passed to the provider
    * `:plug` — a Req test plug for stubbing HTTP responses in tests
  """
  @spec stream_text(Model.ref() | Model.t(), term(), keyword()) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream_text(model, context, opts \\ [])

  def stream_text({provider_id, model_id}, context, opts) do
    with {:ok, model} <- Model.get(provider_id, model_id) do
      stream_text(model, context, opts)
    end
  end

  def stream_text(%Model{} = model, context, opts) do
    context = Context.new(context)
    {raw, opts} = Keyword.pop(opts, :raw, false)
    {max_steps, opts} = Keyword.pop(opts, :max_steps, :infinity)

    Loop.stream(model, context, opts, raw, max_steps)
  end

  @doc group: :generation
  @doc """
  Generates text by consuming a streaming response to completion.

  Accepts the same arguments as `stream_text/3`. Equivalent to calling
  `stream_text/3` and then `StreamingResponse.complete/1`.

  Returns `{:ok, %Response{}}` with the assistant's message, token usage,
  stop reason, and structured output (when `:output` is set).
  """
  @spec generate_text(Model.ref() | Model.t(), term(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def generate_text(model, context, opts \\ []) do
    with {:ok, stream} <- stream_text(model, context, opts) do
      StreamingResponse.complete(stream)
    end
  end

  # -- Delegates --

  @doc group: :models
  @doc """
  Looks up a model by provider and model ID.

  Returns `{:ok, model}` if found, `{:error, {:unknown_provider, id}}` if the
  provider isn't loaded, or `{:error, {:unknown_model, provider_id, model_id}}`
  if the model doesn't exist.

      {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-4-5-20250514")
      model.context_size  #=> 200000
  """
  @spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc group: :models
  @doc """
  Lists all models for a provider.

      {:ok, models} = Omni.list_models(:anthropic)
      Enum.map(models, & &1.id)
      #=> ["claude-sonnet-4-5-20250514", "claude-haiku-4-5", ...]
  """
  @spec list_models(atom()) :: {:ok, [Model.t()]} | {:error, term()}
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc group: :constructors
  @doc """
  Creates a `%Tool{}` struct from a keyword list or map.

  For inline tools with a handler function. For reusable tool modules with
  validation, see `Omni.Tool`.

      Omni.tool(
        name: "search",
        description: "Searches the web",
        input_schema: Omni.Schema.object(%{query: Omni.Schema.string()}, required: [:query]),
        handler: fn input -> do_search(input.query) end
      )
  """
  @spec tool(Enumerable.t()) :: Omni.Tool.t()
  defdelegate tool(attrs), to: Omni.Tool, as: :new

  @doc group: :constructors
  @doc """
  Creates a `%Context{}` from a string, list of messages, keyword list, or map.

  A string is treated as a single user message. A list of `%Message{}` structs
  is treated as the message history. A keyword list or map can set `:system`,
  `:messages`, and `:tools`.

      Omni.context("Hello!")
      Omni.context(system: "You are helpful.", messages: [...], tools: [...])
  """
  @spec context(String.t() | [Omni.Message.t()] | Context.t() | Enumerable.t()) :: Context.t()
  defdelegate context(input), to: Omni.Context, as: :new

  @doc group: :constructors
  @doc """
  Creates a `%Message{}` from a string, keyword list, or map.

  A string is treated as a user message. A keyword list or map can set
  `:role` and `:content`.

      Omni.message("What is Elixir?")
      Omni.message(role: :assistant, content: "Elixir is...")
  """
  @spec message(String.t() | Enumerable.t()) :: Omni.Message.t()
  defdelegate message(input), to: Omni.Message, as: :new
end
