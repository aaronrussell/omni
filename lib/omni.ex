defmodule Omni do
  @moduledoc """
  ![Omni](https://raw.githubusercontent.com/aaronrussell/omni/main/media/poster.webp)

  Universal Elixir client for LLM APIs. Text generation, tool use, structured
  output and decisions across many providers.

  This module is the whole top-level API. New to Omni?
  [Getting started](getting-started.md) is the place to begin.

  ## Text generation

  `generate_text/3` sends a context to a model and returns the finished
  response. `stream_text/3` takes the same arguments and returns events as
  the model writes. Tools in the context are run for you, and `:output`
  asks for a validated map in place of prose.

  ```elixir
  {:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", "Hello!")

  response.message
  #=> %Omni.Message{role: :assistant, content: [%Omni.Content.Text{text: "Hello! How can..."}]}
  ```

  [Text generation](text-generation.md) covers conversations, streaming,
  thinking, tools and structured output.

  ## Decisions

  `decide/3` asks a decision model typed questions about a shared state and
  returns a probability for each answer.

  ```elixir
  {:ok, decision} =
    Omni.decide("openrouter:typesafe/jev-1.14", {ticket_text, [
      urgent: Omni.predicate("Does this need a reply within the hour?")
    ]})

  decision.answers[:urgent]
  #=> %Omni.Answer.Predicate{probability: 0.91}
  ```

  [Decisions](decisions.md) covers the question types and their answers.

  ## Models

  Every request names a model, as an `Omni.Model` or a reference to one: a
  `{provider_id, model_id}` tuple or a `"provider_id:model_id"` string.
  `get_model/1` and `list_models/1` look models up.

  ```elixir
  {:ok, models} = Omni.list_models(:anthropic)
  ```

  [Providers and models](providers-and-models.md) covers choosing and
  configuring providers, adding your own, and where model data comes from.

  ## Building requests

  `context/1`, `message/1`, `tool/1`, `attachment/2` and `tool_result/1`
  build what goes into a text request. `predicate/2`, `choice/2` and
  `score/2` build the questions of a decision. Each is a shortcut for the
  `new` function of the struct it returns.
  """

  alias Omni.{Context, Decision, Loop, Model, Request, Response, StreamingResponse}

  @doc group: :generation
  @doc """
  Streams a text generation request.

  Returns an `Omni.StreamingResponse`: enumerate it for events as the model
  writes, or call `Omni.StreamingResponse.complete/1` for the finished
  response.

  The model is an `Omni.Model` or a reference to one: a
  `{provider_id, model_id}` tuple or a `"provider_id:model_id"` string (see
  `t:Omni.Model.ref/0`). The context is a string, a list of messages, or an
  `Omni.Context`.

  ```elixir
  {:ok, stream} = Omni.stream_text("anthropic:claude-sonnet-5-5", "Tell me a story")

  stream
  |> Omni.StreamingResponse.text_stream()
  |> Enum.each(&IO.write/1)
  ```

  When the context holds tools with handlers, Omni runs each tool the model
  uses and sends the results back, until the model stops using tools. A
  `:tool_result` event is emitted for each result along the way.

  ## Options

  - `:max_tokens` - maximum output tokens (Anthropic defaults to 4096)
  - `:temperature` - sampling temperature
  - `:thinking` - how much the model reasons before answering. Ignored for
    models that don't reason.
    - `true` - on, at `:medium`
    - `:low`, `:medium`, `:high`, `:xhigh` or `:max` - an effort level,
      rounded to the nearest the model supports, or turned into a token
      budget for models that take one
    - `%{effort: level, budget: tokens}` - an exact budget, for models
      that take one
    - `false` - off, where the model can be switched off
  - `:output` - a JSON Schema map for structured output (see
    [Structured output](text-generation.md#structured-output))
  - `:cache` - prompt caching: `:short` for the provider's standard cache
    lifetime, `:long` for its extended one where it has one
  - `:max_steps` - the most requests the tool loop may make (default
    `:infinity`). Pass `1` to run tools yourself
  - `:tool_timeout` - how long each tool may run, in milliseconds (default
    `30_000`)
  - `:timeout` - how long to wait for each chunk of the response, in
    milliseconds (default `300_000`). A response that keeps streaming is not
    cut off; use `:max_tokens` to bound its length
  - `:api_key` - API key, overriding provider and app config
  - `:host` - an origin (`"http://localhost:4000"`) replacing the origin of
    the endpoint URL for this request; the path is kept (see `Omni.Provider`)
  - `:headers` - extra request headers, merged over the provider's
  - `:metadata` - a map passed to the provider
  - `:raw` - when `true`, attaches raw `{%Req.Request{}, %Req.Response{}}`
    tuples to the response (one per request)
  - `:plug` - a Req test plug for stubbing HTTP responses in tests
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
  Generates text and returns the finished response.

  Takes the same arguments and options as `stream_text/3`: it is
  `stream_text/3` followed by `Omni.StreamingResponse.complete/1`.

  Returns an `Omni.Response` with the assistant's message, token usage,
  stop reason, and structured output (when `:output` is set).

  ```elixir
  {:ok, response} = Omni.generate_text("anthropic:claude-sonnet-5-5", "Hello!")
  response.message  #=> %Omni.Message{role: :assistant, content: [%Omni.Content.Text{...}]}
  ```
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

  The model is an `Omni.Model` or a reference to one (see `stream_text/3`),
  and must serve decisions (see `Omni.Model.capability?/2`). The decision is
  an `Omni.Decision` or the shorthand `{state, questions}`
  (`t:Omni.Decision.input/0`): the state is a string, a map, or a list of
  them, and the questions a keyword list built with `predicate/2`,
  `choice/2` and `score/2`.

  ```elixir
  {:ok, decision} =
    Omni.decide("openrouter:typesafe/jev-1.14", {"I was charged twice", [
      refund: Omni.predicate("Is the customer asking for a refund?"),
      tone: Omni.choice("What is the tone?", [:calm, :frustrated, :angry])
    ]})

  decision.answers[:refund]  #=> %Omni.Answer.Predicate{probability: 0.97}
  decision.usage             #=> %Omni.Usage{input_tokens: 61, total_cost: 2.6e-6, ...}
  ```

  Returns the decision with `:answers`, `:usage` and `:model` filled in. A
  model with no decision dialect returns
  `{:error, {:unsupported_capability, :decision}}`; invalid questions are an
  error before any request is made.

  ## Options

  - `:api_key` - API key, overriding provider and app config
  - `:host` - an origin (`"http://localhost:4000"`) replacing the origin of
    the endpoint URL for this request; the path is kept (see `Omni.Provider`)
  - `:headers` - extra request headers, merged over the provider's
  - `:timeout` - how long to wait for the response, in milliseconds
    (default `300_000`)
  - `:raw` - when `true`, attaches the raw `{%Req.Request{}, %Req.Response{}}`
    pair to the decision
  - `:plug` - a Req test plug for stubbing HTTP responses in tests

  A dialect may take more: `Omni.Dialects.OpenAIDecisions` takes
  `:safety_identifier` and `:prompt_cache_key`.
  """
  @spec decide(Model.ref() | Model.t(), Decision.t() | Decision.input(), keyword()) ::
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
  Looks up a model by provider id and model id.

  Returns `{:ok, model}` if found, `{:error, {:unknown_provider, id}}` if the
  provider isn't loaded (it doesn't exist, or isn't selected in
  `config :omni, :models, providers:`), or
  `{:error, {:unknown_model, provider_id, model_id}}` if the model doesn't
  exist.

  ```elixir
  {:ok, model} = Omni.get_model(:anthropic, "claude-sonnet-5-5")
  model.context_size  #=> 1000000
  ```
  """
  @spec get_model(atom(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc group: :models
  @doc """
  Looks up a model by reference.

  A reference is a `{provider_id, model_id}` tuple or a
  `"provider_id:model_id"` string (a slash works too).

  ```elixir
  {:ok, model} = Omni.get_model("anthropic:claude-sonnet-5-5")
  {:ok, model} = Omni.get_model("openrouter/typesafe/jev-1.14")
  ```

  A malformed string is `{:error, {:invalid_model_ref, ref}}`; otherwise the
  errors are those of `get_model/2`. See `Omni.Model` for the reference forms.
  """
  @spec get_model(Model.ref()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate get_model(ref), to: Omni.Model, as: :get

  @doc group: :models
  @doc """
  Registers a model under its provider at runtime.

  The model can then be found by `get_model/2` and `list_models/1`. See
  `Omni.Model.put/1`.

  ```elixir
  model =
    Omni.Model.new(
      id: "my-fine-tune",
      name: "My Fine-Tune",
      provider: :openai,
      dialects: %{text: Omni.Dialects.OpenAIResponses}
    )

  Omni.put_model(model)
  ```
  """
  @spec put_model(Model.t()) :: :ok
  defdelegate put_model(model), to: Omni.Model, as: :put

  @doc group: :models
  @doc """
  Looks up a loaded provider by id.

  Returns `{:ok, provider}`, or `{:error, {:unknown_provider, id}}` if no
  provider with that id is loaded.

  ```elixir
  {:ok, provider} = Omni.get_provider(:anthropic)
  provider.name  #=> "Anthropic"
  ```
  """
  @spec get_provider(atom()) :: {:ok, Omni.Provider.t()} | {:error, term()}
  defdelegate get_provider(id), to: Omni.Provider, as: :get

  @doc group: :models
  @doc """
  Lists all models for a provider.

  ```elixir
  {:ok, models} = Omni.list_models(:anthropic)
  Enum.map(models, & &1.id)
  #=> ["claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5", ...]
  ```
  """
  @spec list_models(atom()) :: {:ok, [Model.t()]} | {:error, term()}
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc group: :context
  @doc """
  Creates a tool from a keyword list or map.

  For inline tools with a handler function. For reusable tool modules, see
  `Omni.Tool`.

  ```elixir
  Omni.tool(
    name: "search",
    description: "Searches the web",
    input_schema: Omni.Schema.object(%{query: Omni.Schema.string()}, required: [:query]),
    handler: fn input -> do_search(input.query) end
  )
  ```
  """
  @spec tool(Enumerable.t()) :: Omni.Tool.t()
  defdelegate tool(attrs), to: Omni.Tool, as: :new

  @doc group: :context
  @doc """
  Creates an attachment content block from a keyword list or map.

  See `Omni.Content.Attachment.new/1`.

  ```elixir
  Omni.attachment(source: {:url, "https://example.com/cat.png"}, media_type: "image/png", meta: %{name: "cat.png"})
  ```
  """
  @spec attachment(Enumerable.t()) :: Omni.Content.Attachment.t()
  defdelegate attachment(attrs), to: Omni.Content.Attachment, as: :new

  @doc group: :context
  @doc """
  Creates an attachment content block from a source and media type.

  The source is `{:base64, data}` (base64-encoded) or `{:url, url}`. See
  `Omni.Content.Attachment`.

  ```elixir
  Omni.message(role: :user, content: [
    "What's in this image?",
    Omni.attachment({:base64, Base.encode64(File.read!("photo.png"))}, "image/png")
  ])
  ```
  """
  @spec attachment(Omni.Content.Attachment.source(), String.t()) :: Omni.Content.Attachment.t()
  defdelegate attachment(source, media_type), to: Omni.Content.Attachment, as: :new

  @doc group: :context
  @doc """
  Creates a tool result content block from a keyword list or map.

  For running tools yourself instead of through the loop: answer each
  `Omni.Content.ToolUse` with a result in the next user message. String
  content is wrapped in a text block. See `Omni.Content.ToolResult`.

  ```elixir
  Omni.message(role: :user, content: [
    Omni.tool_result(tool_use_id: tool_use.id, name: tool_use.name, content: "72°F and sunny")
  ])
  ```
  """
  @spec tool_result(Enumerable.t()) :: Omni.Content.ToolResult.t()
  defdelegate tool_result(attrs), to: Omni.Content.ToolResult, as: :new

  @doc group: :decisions
  @doc """
  Creates a yes/no question for `decide/3`.

  See `Omni.Question.Predicate.new/2`.

  ```elixir
  Omni.predicate("Is this spam?", true: "Unsolicited advertising", false: "A real conversation")
  ```
  """
  @spec predicate(Omni.Question.instructions_input(), [{boolean(), String.t()}] | nil) ::
          Omni.Question.Predicate.t()
  defdelegate predicate(instructions, criteria \\ nil), to: Omni.Question.Predicate, as: :new

  @doc group: :decisions
  @doc """
  Creates a question with one answer from a set of choices, for `decide/3`.

  See `Omni.Question.Choice.new/2`.

  ```elixir
  Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil)
  ```
  """
  @spec choice(Omni.Question.instructions_input(), list()) :: Omni.Question.Choice.t()
  defdelegate choice(instructions, choices), to: Omni.Question.Choice, as: :new

  @doc group: :decisions
  @doc """
  Creates a question rating the state on an ordered scale, for `decide/3`.

  See `Omni.Question.Score.new/2`.

  ```elixir
  Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
  ```
  """
  @spec score(Omni.Question.instructions_input(), list()) :: Omni.Question.Score.t()
  defdelegate score(instructions, levels), to: Omni.Question.Score, as: :new

  @doc group: :context
  @doc """
  Creates a context from a string, list of messages, keyword list, or map.

  A string is a single user message. A list of messages is the message
  history. A keyword list or map sets `:system`, `:messages` and `:tools`.
  See `Omni.Context`.

  ```elixir
  Omni.context("Hello!")
  Omni.context(system: "You are helpful.", messages: [...], tools: [...])
  ```
  """
  @spec context(String.t() | [Omni.Message.t()] | Context.t() | Enumerable.t()) :: Context.t()
  defdelegate context(input), to: Omni.Context, as: :new

  @doc group: :context
  @doc """
  Creates a message from a string, keyword list, or map.

  A string is a user message. A keyword list or map sets `:role` and
  `:content`. See `Omni.Message.new/1`.

  ```elixir
  Omni.message("What is Elixir?")
  Omni.message(role: :assistant, content: "Elixir is...")
  ```
  """
  @spec message(String.t() | Enumerable.t()) :: Omni.Message.t()
  defdelegate message(input), to: Omni.Message, as: :new
end
