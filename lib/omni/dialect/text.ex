defmodule Omni.Dialect.Text do
  @moduledoc """
  Behaviour for text generation dialects.

  A text dialect builds a streaming request from a `%Omni.Context{}` and
  parses each decoded stream event into delta tuples, which
  `Omni.StreamingResponse` folds into a response. Declare it with
  `use Omni.Dialect, :text`, which also sets the base `Omni.Dialect`
  behaviour (`c:Omni.Dialect.auth/0`, `c:Omni.Dialect.compat_schema/0`).

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
  `:private` (map merged into `Message.private`: list values append across
  events, other values replace; `c:handle_message/2` can reshape the result).

  ### `:block_start`

  Signals the start of a new content block. Requires `:type` and `:index`:

      {:block_start, %{type: :text, index: 0}}
      {:block_start, %{type: :thinking, index: 0}}
      {:block_start, %{type: :tool_use, index: 1, id: "call_1", name: "weather"}}

  The `:type` determines the consumer event name (`:text_start`, `:thinking_start`,
  `:tool_use_start`). Tool use blocks include `:id` and `:name`. Thinking blocks
  may include `:id`, for APIs that refer to reasoning by id on replay, and
  `:redacted_data`.

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

  ## Thinking

  Dialects translate the `:thinking` option with `Omni.Dialect.Thinking`,
  which resolves it against the model's thinking data.

  ## Implementing a text dialect

  Dialects are stateless and pure — every callback receives
  already-validated inputs and returns plain data. No HTTP, no configuration,
  no side effects.

      defmodule MyApp.Dialects.CustomFormat do
        use Omni.Dialect, :text

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

  alias Omni.{Context, Message, Model}

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

  The path is the API's resource path, appended to the base URL of the
  provider's endpoint for the dialect. The base URL carries any version
  segment (`https://api.openai.com/v1`), so the path does not. Most dialects
  return a static path:

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

  Read the provider's compat flags with `Omni.Dialect.compat/2`. The
  returned map may be further adjusted by the provider module's
  `c:Omni.Provider.modify_body/4` before being sent as JSON.
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

  @doc """
  Finishes the assembled assistant message once a stream completes.

  Optional. Called once, on the message of the `:done` response, after every
  event has been folded in. Use it for work that needs the whole stream
  rather than one event, such as merging replay data captured in fragments
  into the shape the API takes back. Not called when a stream ends in an
  error or is cancelled. Without it, the message is used as assembled.

      def handle_message(%Message{private: %{chunks: chunks}} = message, _model) do
        %{message | private: %{message.private | chunks: merge(chunks)}}
      end
  """
  @callback handle_message(Message.t(), Model.t()) :: Message.t()

  @optional_callbacks handle_message: 2
end
