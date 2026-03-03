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

  ## Delta types

  `c:handle_event/1` returns a list of `{type, map}` delta tuples.
  `Omni.StreamingResponse` consumes these to build the event stream users
  interact with. There are four delta types:

  ### `:message`

  Carries message-level metadata. Does not produce a consumer event directly —
  the data is folded into the accumulating response.

      {:message, %{model: "claude-sonnet-4-5-20250514"}}
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

  ## Implementing a dialect

  A dialect module declares `@behaviour Omni.Dialect` and implements all four
  callbacks. Dialects are stateless and pure — every callback receives
  already-validated inputs and returns plain data. No HTTP, no configuration,
  no side effects.

      defmodule MyApp.Dialects.CustomFormat do
        @behaviour Omni.Dialect

        @impl true
        def option_schema, do: %{}

        @impl true
        def handle_path(_model, _opts), do: "/v1/generate"

        @impl true
        def handle_body(model, context, opts) do
          %{
            "model" => model.id,
            "messages" => encode_messages(context.messages),
            "stream" => true
          }
        end

        @impl true
        def handle_event(%{"type" => "text", "content" => text}) do
          [{:block_delta, %{type: :text, index: 0, delta: text}}]
        end

        def handle_event(_), do: []
      end
  """

  alias Omni.{Context, Model}

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
  Returns the URL path for the given model and options.

  The returned path is passed to `c:Omni.Provider.build_url/2`, which
  typically concatenates it with the provider's base URL. Most dialects
  return a static path:

      def handle_path(_model, _opts), do: "/v1/chat/completions"

  Some API families interpolate the model ID into the path (e.g. Google
  Gemini uses `/v1beta/models/{model}:streamGenerateContent`).
  """
  @callback handle_path(Model.t(), map()) :: String.t()

  @doc """
  Builds the request body from a model, context, and validated options.

  This is where Omni types become the API's native JSON structure — messages
  are reshaped, content blocks encoded, tools serialized, and options mapped
  to API parameters. The options have already been validated and include
  defaults, so no fallback values are needed.

  Always set `"stream" => true` (or the equivalent for the API format).

  The returned map may be further adjusted by the provider's
  `c:Omni.Provider.modify_body/3` before being sent as JSON.
  """
  @callback handle_body(Model.t(), Context.t(), map()) :: map()

  @doc """
  Parses a single decoded SSE event map into a list of delta tuples.

  Receives one JSON-decoded event from the SSE stream. Returns a list of
  delta tuples (see the "Delta types" section in the moduledoc). Most deltas
  are `{type, map}` pairs; `:error` is `{:error, reason}` with a bare term.
  Return `[]` to skip an event the dialect doesn't need to handle.

  The function must be stateless and pure — it receives one event and returns
  deltas with no knowledge of previous events. This makes dialects trivially
  testable: pass a JSON map, assert the tuples that come out.

  The returned deltas may be further adjusted by the provider's
  `c:Omni.Provider.modify_events/2` before reaching the consumer.
  """
  @callback handle_event(map()) :: [{atom(), map() | term()}]
end
