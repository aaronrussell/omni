defmodule Omni.Dialect do
  @moduledoc """
  Behaviour for wire format translation between Omni types and provider APIs.

  A dialect handles the pure data transformation layer: building request bodies
  from Omni structs and parsing streaming events into normalized delta tuples.
  Each dialect corresponds to a specific API format (e.g. Anthropic Messages,
  OpenAI Chat Completions).

  Most custom integrations only need a new provider, not a new dialect —
  implement a dialect only when the provider speaks a wire format not covered
  by the existing modules. See `Omni.Provider` for the broader integration
  story and how providers and dialects compose.

  ## Available dialects

    * `Omni.Dialects.OpenAICompletions` — OpenAI Chat Completions format, used
      by most third-party providers (Groq, Together, Fireworks, DeepSeek, etc.)
    * `Omni.Dialects.OpenAIResponses` — OpenAI's newer Responses API format
    * `Omni.Dialects.AnthropicMessages` — Anthropic Messages format
    * `Omni.Dialects.GoogleGemini` — Google Gemini format
    * `Omni.Dialects.OllamaChat` — Ollama native chat format (NDJSON streaming)

  ## Dialect registry

  Built-in dialects are registered with string identifiers for use in model
  catalog data (e.g. `"anthropic_messages"`, `"openai_responses"`). Use `get/1`
  or `get!/1` to resolve a string to its module. This is primarily used by
  model sources (see `Omni.Source.build_model/1`) when mapping catalog data
  to dialects.

  ## Delta types

  `c:handle_event/2` returns a list of `{type, map}` delta tuples.
  `Omni.StreamingResponse` consumes these to build the event stream users
  interact with. There are four delta types:

  ### `:message`

  Carries message-level metadata. Does not produce a consumer event directly —
  the data is folded into the accumulating response.

      {:message, %{model: "claude-sonnet-5-5"}}
      {:message, %{stop_reason: :stop, usage: %{...}}}
      {:message, %{private: %{key: value}}}

  Recognized keys: `:model` (string), `:stop_reason` (atom), `:usage` (map),
  `:private` (map merged into `Message.private`).

  ### `:block_start`

  Signals the start of a new content block. Requires `:type` and `:index`:

      {:block_start, %{type: :text, index: 0}}
      {:block_start, %{type: :thinking, index: 0}}
      {:block_start, %{type: :tool_use, index: 1, id: "call_1", name: "weather"}}

  The `:type` determines the consumer event name (`:text_start`, `:thinking_start`,
  `:tool_use_start`). Tool use blocks include `:id` and `:name`.

  ### `:block_delta`

  An incremental update to a content block. Requires `:type`, `:index`, and
  typically `:delta`:

      {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
      {:block_delta, %{type: :thinking, index: 0, delta: "Let me think..."}}
      {:block_delta, %{type: :tool_use, index: 1, delta: "{\\"city\\":"}}

  The `:delta` is a string fragment. For thinking blocks, `:signature` may be
  included for round-trip integrity tokens.

  ### `:error`

  Signals a streaming error. Unlike the other delta types, `:error` carries a
  bare reason term rather than a map — matching Elixir's `{:error, reason}`
  convention:

      {:error, "overloaded_error"}

  ## Compat flags

  Providers that speak a dialect with small deviations from its home API
  describe them as compat flags, which the dialect declares in
  `c:compat_schema/0` and reads with `compat/2` while it encodes. A
  provider's flags are validated against the schema when it loads. See
  `Omni.Dialects.OpenAICompletions` for the flags it understands.

  ## Thinking

  Dialects translate the `:thinking` option with `Omni.Dialect.Thinking`,
  which resolves it against the model's thinking data.

  ## Implementing a dialect

  A dialect module declares `@behaviour Omni.Dialect` and implements all six
  callbacks. Dialects are stateless and pure — every callback receives
  already-validated inputs and returns plain data. No HTTP, no configuration,
  no side effects.

      defmodule MyApp.Dialects.CustomFormat do
        @behaviour Omni.Dialect

        @impl true
        def option_schema, do: %{}

        @impl true
        def compat_schema, do: %{}

        @impl true
        def auth, do: :bearer

        @impl true
        def handle_path(_model, _opts), do: "/generate"

        @impl true
        def handle_body(model, context, opts) do
          %{
            "model" => model.id,
            "messages" => encode_messages(context.messages),
            "stream" => true
          }
        end

        @impl true
        def handle_event(%{"type" => "text", "content" => text}, _model) do
          [{:block_delta, %{type: :text, index: 0, delta: text}}]
        end

        def handle_event(_event, _model), do: []
      end
  """

  alias Omni.{Context, Model, Provider}

  @registry %{
    "anthropic_messages" => Omni.Dialects.AnthropicMessages,
    "openai_completions" => Omni.Dialects.OpenAICompletions,
    "openai_responses" => Omni.Dialects.OpenAIResponses,
    "google_gemini" => Omni.Dialects.GoogleGemini,
    "ollama_chat" => Omni.Dialects.OllamaChat
  }

  @doc """
  Resolves a dialect string identifier to its module.

  Built-in dialect identifiers: `"anthropic_messages"`, `"openai_completions"`,
  `"openai_responses"`, `"google_gemini"`, `"ollama_chat"`.
  """
  @spec get(String.t()) :: {:ok, module()} | {:error, {:unknown_dialect, String.t()}}
  def get(name) when is_binary(name) do
    case @registry[name] do
      nil -> {:error, {:unknown_dialect, name}}
      mod -> {:ok, mod}
    end
  end

  @doc """
  Resolves a dialect string identifier to its module, raising on failure.
  """
  @spec get!(String.t()) :: module()
  def get!(name) when is_binary(name) do
    case get(name) do
      {:ok, mod} -> mod
      {:error, reason} -> raise ArgumentError, "#{inspect(reason)}"
    end
  end

  @doc """
  Returns the compat flags a provider has set for a dialect.

  Reads `model.provider.compat[dialect]`, returning `%{}` when the provider
  sets none (or the model has no provider):

      compat = Omni.Dialect.compat(model, __MODULE__)
      field = Map.get(compat, :max_tokens_field, "max_completion_tokens")
  """
  @spec compat(Model.t(), module()) :: map()
  def compat(%Model{provider: %Provider{compat: compat}}, dialect),
    do: Map.get(compat, dialect, %{})

  def compat(%Model{}, _dialect), do: %{}

  @doc """
  Returns a Peri schema map for dialect-specific options.

  The returned schema is merged with Omni's universal option schema (which
  covers `:max_tokens`, `:temperature`, `:cache`, `:thinking`, etc.) and
  validated in a single pass before any other callback runs. Use this to
  declare options unique to the API format, such as required parameters with
  defaults:

      def option_schema do
        %{max_tokens: {:integer, {:default, 4096}}}
      end

  Return an empty map if the dialect has no additional options.
  """
  @callback option_schema() :: Peri.map_schema()

  @doc """
  Returns a Peri schema map for the compat flags this dialect understands.

  A provider's `:compat` flags for the dialect are validated against it when
  the provider loads; unknown flags are a boot error. Each flag describes a
  deviation from the dialect's home API, so an absent flag means home-API
  behaviour:

      def compat_schema do
        %{max_tokens_field: :string, omit: {:list, {:enum, [:cache]}}}
      end

  Return an empty map if the dialect has no flags.
  """
  @callback compat_schema() :: Peri.map_schema()

  @doc """
  Returns how this dialect's home API expects the API key to be sent.

  Used for providers whose `:auth` is `:dialect` (the default), so a
  provider speaking a dialect authenticates the way that dialect's reference
  API does — and a gateway serving several dialects authenticates each model
  correctly:

      def auth, do: {:header, "x-api-key"}

  Return `:bearer` for an `Authorization: Bearer <key>` header, or
  `{:header, name}` to send the raw key on a named header.
  """
  @callback auth() :: :bearer | {:header, String.t()}

  @doc """
  Returns the URL path for the given model and options.

  The path is the API's resource path, appended to the provider's base URL.
  The base URL carries any version segment (`https://api.openai.com/v1`), so
  the path does not. Most dialects return a static path:

      def handle_path(_model, _opts), do: "/chat/completions"

  Some API families interpolate the model ID into the path (e.g. Google
  Gemini uses `/models/{model}:streamGenerateContent`).
  """
  @callback handle_path(Model.t(), map()) :: String.t()

  @doc """
  Builds the request body from a model, context, and validated options.

  This is where Omni types become the API's native JSON structure — messages
  are reshaped, content blocks encoded, tools serialized, and options mapped
  to API parameters. The options have already been validated and include
  defaults, so no fallback values are needed.

  Always set `"stream" => true` (or the equivalent for the API format).

  Read the provider's compat flags with `compat/2`. The returned map may be
  further adjusted by the provider module's `c:Omni.Provider.modify_body/4`
  before being sent as JSON.
  """
  @callback handle_body(Model.t(), Context.t(), map()) :: map()

  @doc """
  Parses a single decoded stream event into a list of delta tuples.

  Receives one JSON-decoded event from the stream, and the model the request
  was made with (for its compat flags). Returns a list of
  delta tuples (see the "Delta types" section in the moduledoc). Most deltas
  are `{type, map}` pairs; `:error` is `{:error, reason}` with a bare term.
  Return `[]` to skip an event the dialect doesn't need to handle.

  The function must be stateless and pure — it receives one event and returns
  deltas with no knowledge of previous events. This makes dialects trivially
  testable: pass a JSON map, assert the tuples that come out.
  """
  @callback handle_event(event :: map(), Model.t()) :: [{atom(), map() | term()}]
end
