defmodule Omni do
  @moduledoc """
  ![Omni](https://raw.githubusercontent.com/aaronrussell/omni/main/media/poster.webp)

  ![License](https://img.shields.io/github/license/aaronrussell/omni?color=informational)

  Universal Elixir client for LLM APIs. Streaming text generation, tool use, and structured output.

  Omni provides a single API for text generation that works with many LLM
  providers. Text requests are streaming-first — `generate_text/3` is built
  on top of `stream_text/3`. Decision models answer typed questions with
  probabilities through `decide/3`.

  ## Setup

  Add Omni to your dependencies:

      {:omni, "~> 2.0"}

  Each built-in provider reads its API key from a standard environment variable
  by default — if your keys are set, no configuration is needed:

  | Provider | Id | Environment variable |
  | --- | --- | --- |
  | Alibaba | `:alibaba` | `DASHSCOPE_API_KEY` |
  | Anthropic | `:anthropic` | `ANTHROPIC_API_KEY` |
  | Google | `:google` | `GEMINI_API_KEY` |
  | Groq | `:groq` | `GROQ_API_KEY` |
  | Mistral AI | `:mistral` | `MISTRAL_API_KEY` |
  | Moonshot AI | `:moonshotai` | `MOONSHOT_API_KEY` |
  | NEAR AI Cloud | `:nearai` | `NEARAI_API_KEY` |
  | Ollama Cloud | `:ollama_cloud` | `OLLAMA_API_KEY` |
  | OpenAI | `:openai` | `OPENAI_API_KEY` |
  | OpenCode | `:opencode` | `OPENCODE_API_KEY` |
  | OpenRouter | `:openrouter` | `OPENROUTER_API_KEY` |
  | Together AI | `:togetherai` | `TOGETHER_API_KEY` |
  | TypeSafe (decisions only) | `:typesafe` | `TYPESAFE_API_KEY` |
  | Venice AI | `:venice` | `VENICE_API_KEY` |
  | xAI | `:xai` | `XAI_API_KEY` |
  | Z.ai | `:zai` | `ZAI_API_KEY` |

  A provider for a local Ollama instance (`:ollama`) is also built in. It
  needs no key; list the models you have pulled (see `Omni.Providers.Ollama`).

  To override a key — for example, to use a different variable name or load
  from a vault at runtime — configure the provider by id:

      # config/runtime.exs
      config :omni, :providers,
        anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}],
        openai: [api_key: {MyApp.Secrets, :fetch, ["openai"]}]

  You can also pass `:api_key` directly to `generate_text/3`, `stream_text/3`
  or `decide/3`.

  All built-in providers are loaded by default. To choose what loads at
  startup, list provider ids (`:builtins` names all built-ins and may appear
  in the list):

      config :omni, :models,
        providers: [:anthropic, :openai]

  ## Text generation

  The simplest way to use Omni — pass a model tuple and a string:

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, "Hello!")

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

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, context)

  ## Streaming

  `stream_text/3` returns a `StreamingResponse` that you can consume with
  event handlers:

      {:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-5-5"}, "Tell me a story")

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
          {:anthropic, "claude-sonnet-5-5"},
          "What is the capital of France?",
          output: schema
        )

      response.output
      #=> %{name: "Paris", population: 2161000}

  The schema is sent to the provider for constrained decoding. The response
  text is validated against the schema and decoded into `response.output`,
  with automatic retries on validation failure.

  ## Tool use

  Define tools with schemas and handlers — the loop automatically executes tool
  uses and feeds results back to the model:

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

      {:ok, response} = Omni.generate_text({:anthropic, "claude-sonnet-5-5"}, context)

  When tools have handlers, the loop automatically executes tool uses and feeds
  results back to the model until it produces a final text response.

  For reusable tools with validation, define a tool module — see `Omni.Tool`.

  ## Decisions

  Decision models answer typed questions about a shared input with
  calibrated probabilities instead of prose. Pass the input and a keyword
  list of questions:

      {:ok, decision} =
        Omni.decide({:openrouter, "typesafe/jev-1.14"}, {ticket_text, [
          urgent: Omni.predicate("Does this need a reply within the hour?"),
          team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
          anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
        ]})

      decision.answers[:urgent]  #=> %Omni.Answer.Predicate{probability: 0.91}
      decision.answers[:team]    #=> %Omni.Answer.Choice{choice: :infra, probabilities: [billing: 0.02, infra: 0.95, other: 0.03], confidence: 0.93}

  See `Omni.Decision` and `Omni.Question`.

  ## Providers

  Models are referenced as `{provider_id, model_id}` tuples or as
  `"provider_id:model_id"` strings (a slash works too; see
  `Omni.Model`). To list a provider's models:

      {:ok, models} = Omni.list_models(:anthropic)

  Beyond the built-ins, any provider in the models.dev catalog can be loaded
  by its id, and a provider the catalog doesn't know can be defined wholly in
  config:

      config :omni, :models, providers: [:builtins, :fireworks_ai]

  Each model names the dialect it speaks: the wire format of an API family,
  such as `Omni.Dialects.OpenAICompletions`. Most providers use one dialect;
  gateways like OpenCode Zen use a different one per model. See
  `Omni.Provider` for configuring and defining providers.
  """

  alias Omni.{Context, Decision, Loop, Model, Request, Response, StreamingResponse}

  @doc group: :generation
  @doc """
  Streams a text generation request, returning a `%StreamingResponse{}`.

  The model can be a `%Model{}` struct or a reference: a `{provider_id,
  model_id}` tuple or a `"provider_id:model_id"` string (see `Omni.Model`).
  The context can be a string, list of messages, or `%Context{}` struct.

  When tools with handlers are present in the context, automatically executes
  tool uses and loops until the model stops calling tools. Between rounds,
  synthetic `:tool_result` events are emitted for observability.

  ## Options

    * `:max_tokens` — maximum output tokens (Anthropic defaults to 4096)
    * `:temperature` — sampling temperature (number)
    * `:thinking` — extended thinking. Ignored for models that don't reason.
      * `true` — on, at `:medium`
      * `:low`, `:medium`, `:high`, `:xhigh` or `:max` — an effort level,
        rounded to the nearest the model supports, or turned into a token
        budget for models that take one
      * `%{effort: level, budget: tokens}` — an exact budget, for models
        that take one
      * `false` — off, where the model can be switched off
    * `:output` — a JSON Schema map for structured output (see the
      [Structured output](#module-structured-output) section above)
    * `:max_steps` — maximum tool execution rounds (default `:infinity`).
      Pass `1` to disable auto-looping for manual tool handling
    * `:tool_timeout` — per-tool execution timeout in milliseconds (default `30_000`)
    * `:cache` — prompt caching strategy (`:short` or `:long`)
    * `:timeout` — how long to wait for each chunk of the response, in
      milliseconds (default `300_000`). A response that keeps streaming is not
      cut off; use `:max_tokens` to bound its length
    * `:api_key` — API key, overriding provider/app config
    * `:host` — an origin (`"http://localhost:4000"`) replacing the origin of
      the endpoint URL for this request; the path is kept (see `Omni.Provider`)
    * `:raw` — when `true`, attaches raw `{%Req.Request{}, %Req.Response{}}` tuples
      to the response (one per round)
    * `:metadata` — arbitrary metadata map passed to the provider
    * `:plug` — a Req test plug for stubbing HTTP responses in tests
  """
  @spec stream_text(Model.ref() | Model.t(), term(), keyword()) ::
          {:ok, StreamingResponse.t()} | {:error, term()}
  def stream_text(model, context, opts \\ [])

  def stream_text(%Model{} = model, context, opts) do
    Loop.stream(model, Context.new(context), opts)
  end

  def stream_text(ref, context, opts) when is_binary(ref) or is_tuple(ref) do
    with {:ok, model} <- Model.get(ref) do
      stream_text(model, context, opts)
    end
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

  @doc group: :decisions
  @doc """
  Asks a decision model typed questions about a shared state.

  The model can be a `%Model{}` struct or a reference (see `stream_text/3`),
  and must serve decisions (see `Omni.Model.capability?/2`). The decision is a
  `%Omni.Decision{}` or the shorthand `{state, questions}`: the state is a
  string, a map, or a list of them (see `Omni.Decision`), and the questions
  a keyword list built with `predicate/2`, `choice/2` and `score/2`.

      {:ok, decision} =
        Omni.decide("openrouter:typesafe/jev-1.14", {"I was charged twice", [
          refund: Omni.predicate("Is the customer asking for a refund?"),
          tone: Omni.choice("What is the tone?", [:calm, :frustrated, :angry])
        ]})

      decision.answers[:refund]  #=> %Omni.Answer.Predicate{probability: 0.97}
      decision.usage             #=> %Omni.Usage{input_tokens: 61, total_cost: 2.6e-6, ...}

  Returns `{:ok, %Decision{}}` with `:answers`, `:usage` and `:model`
  filled in. A model with no decision dialect returns
  `{:error, {:unsupported_capability, :decision}}`; invalid questions are an
  error before any request is made.

  ## Options

    * `:api_key` — API key, overriding provider/app config
    * `:host` — an origin (`"http://localhost:4000"`) replacing the origin of
      the endpoint URL for this request; the path is kept (see `Omni.Provider`)
    * `:headers` — extra request headers, merged over the provider's
    * `:timeout` — how long to wait for the response, in milliseconds
      (default `300_000`)
    * `:raw` — when `true`, attaches the raw `{%Req.Request{}, %Req.Response{}}`
      pair to the decision
    * `:plug` — a Req test plug for stubbing HTTP responses in tests

  A dialect may take more: `Omni.Dialects.OpenAIDecisions` takes
  `:safety_identifier` and `:prompt_cache_key`.
  """
  @spec decide(Model.ref() | Model.t(), Decision.t() | {term(), list()}, keyword()) ::
          {:ok, Decision.t()} | {:error, term()}
  def decide(model, decision, opts \\ [])

  def decide(%Model{} = model, decision, opts) do
    decision = Decision.new(decision)
    {raw?, opts} = Keyword.pop(opts, :raw, false)

    with {:ok, req} <- Request.build(model, decision, opts) do
      Request.send(req, model, decision, raw: raw?)
    end
  end

  def decide(ref, decision, opts) when is_binary(ref) or is_tuple(ref) do
    with {:ok, model} <- Model.get(ref) do
      decide(model, decision, opts)
    end
  end

  # -- Delegates --

  @doc group: :models
  @doc """
  Looks up a model by provider and model ID.

  Returns `{:ok, model}` if found, `{:error, {:unknown_provider, id}}` if the
  provider isn't loaded (it doesn't exist, or isn't selected in
  `config :omni, :models, providers:`), or
  `{:error, {:unknown_model, provider_id, model_id}}` if the model doesn't
  exist.

      {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
      model.context_size  #=> 1000000
  """
  @spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc group: :models
  @doc """
  Looks up a model by reference: a `{provider_id, model_id}` tuple or a
  `"provider_id:model_id"` string (a slash works too).

      {:ok, model} = Omni.get_model("anthropic:claude-sonnet-5-5")
      {:ok, model} = Omni.get_model("openrouter/typesafe/jev-1.14")

  A malformed string is `{:error, {:invalid_model_ref, ref}}`; otherwise the
  errors are those of `get_model/2`. See `Omni.Model` for the reference forms.
  """
  @spec get_model(Model.ref()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate get_model(ref), to: Omni.Model, as: :get

  @doc group: :models
  @doc """
  Registers a model for lookup by `get_model/2` and `list_models/1`, under its
  provider.

  See `Omni.Model.put/1` for details.

      model = Omni.Model.new(id: "my-fine-tune", name: "My Fine-Tune", provider: :openai)
      Omni.put_model(model)
  """
  @spec put_model(Model.t()) :: :ok
  defdelegate put_model(model), to: Omni.Model, as: :put

  @doc group: :models
  @doc """
  Looks up a loaded provider by id.

  Returns `{:ok, provider}`, or `{:error, {:unknown_provider, id}}` if no
  provider with that id is loaded.

      {:ok, provider} = Omni.get_provider(:anthropic)
      provider.name  #=> "Anthropic"
  """
  @spec get_provider(atom()) :: {:ok, Omni.Provider.t()} | {:error, term()}
  defdelegate get_provider(id), to: Omni.Provider, as: :get

  @doc group: :models
  @doc """
  Lists all models for a provider.

      {:ok, models} = Omni.list_models(:anthropic)
      Enum.map(models, & &1.id)
      #=> ["claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5", ...]
  """
  @spec list_models(atom()) :: {:ok, [Model.t()]} | {:error, term()}
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc group: :context
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

  @doc group: :decisions
  @doc """
  Creates a yes/no question for `decide/3`.

  See `Omni.Question.predicate/2`.

      Omni.predicate("Is this spam?", true: "Unsolicited advertising", false: "A real conversation")
  """
  @spec predicate(Omni.Question.instructions_input(), [{boolean(), String.t()}] | nil) ::
          Omni.Question.Predicate.t()
  defdelegate predicate(instructions, criteria \\ nil), to: Omni.Question

  @doc group: :decisions
  @doc """
  Creates a question with one answer from a set of choices, for `decide/3`.

  See `Omni.Question.choice/2`.

      Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil)
  """
  @spec choice(Omni.Question.instructions_input(), list()) :: Omni.Question.Choice.t()
  defdelegate choice(instructions, choices), to: Omni.Question

  @doc group: :decisions
  @doc """
  Creates a question rating the state on an ordered scale, for `decide/3`.

  See `Omni.Question.score/2`.

      Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
  """
  @spec score(Omni.Question.instructions_input(), list()) :: Omni.Question.Score.t()
  defdelegate score(instructions, levels), to: Omni.Question

  @doc group: :context
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

  @doc group: :context
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
