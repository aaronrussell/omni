defmodule Omni.Dialect.Text do
  @moduledoc """
  Behaviour for text generation dialects.

  A text dialect builds a streaming request from an `Omni.Context` and
  parses each decoded stream event into delta tuples, which
  `Omni.StreamingResponse` folds into a response. Declare it with
  `use Omni.Dialect, :text`, which also sets the base `Omni.Dialect`
  behaviour (`c:Omni.Dialect.auth/0`, `c:Omni.Dialect.compat_schema/0`).

  ## Delta types

  `c:handle_event/2` returns a list of `{type, map}` delta tuples.
  `Omni.StreamingResponse` consumes these to build the event stream users
  interact with. There are four delta types:

  ### `:message`

  Carries message-level metadata. It produces no consumer event of its own:
  the data is folded into the response being built.

  ```elixir
  {:message, %{model: "claude-sonnet-5-5"}}
  {:message, %{stop_reason: :stop, usage: %{...}}}
  {:message, %{private: %{key: value}}}
  ```

  Recognised keys: `:model` (string), `:stop_reason` (atom), `:usage` (map),
  `:private` (map merged into `Message.private`: list values append across
  events, other values replace; `c:handle_message/2` can reshape the result).

  ### `:block_start`

  Signals the start of a new content block. Requires `:type` and `:index`:

  ```elixir
  {:block_start, %{type: :text, index: 0}}
  {:block_start, %{type: :thinking, index: 0}}
  {:block_start, %{type: :tool_use, index: 1, id: "call_1", name: "weather"}}
  ```

  The `:type` determines the consumer event name (`:text_start`, `:thinking_start`,
  `:tool_use_start`). Tool use blocks include `:id` and `:name`. Thinking blocks
  may include `:id`, for APIs that refer to reasoning by id on replay, and
  `:redacted_data`.

  ### `:block_delta`

  An incremental update to a content block. Requires `:type`, `:index`, and
  typically `:delta`:

  ```elixir
  {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
  {:block_delta, %{type: :thinking, index: 0, delta: "Let me think..."}}
  {:block_delta, %{type: :tool_use, index: 1, delta: "{\\"city\\":"}}
  ```

  The `:delta` is a string fragment. For thinking blocks, `:signature` may be
  included for round-trip integrity tokens.

  ### `:error`

  Signals a streaming error. Unlike the other delta types, `:error` carries
  a bare reason term, not a map, as `{:error, reason}` tuples do in Elixir:

  ```elixir
  {:error, "overloaded_error"}
  ```

  ## Thinking

  Dialects translate the `:thinking` option with `resolve_thinking/2`, then
  spell the result in their wire format. The model's `:thinking` data (see
  `Omni.Model`) decides what is sent, so every dialect agrees on how levels
  map to a model's effort values and budgets:

  - Effort levels are clamped to the model's values on one ladder,
    `minimal < low < medium < high < xhigh < max`: round up to the nearest
    supported value, else down. A model whose only "on" value is
    `"default"` gets `"default"`.
  - Levels and budgets map both ways through one table (`low` 1024,
    `medium` 4096, `high` 16384, `xhigh` 24576, `max` 32768). A level
    gives its budget; a budget gives the smallest level whose budget
    covers it, else `:max`. Budgets are clamped to the model's range.

  `resolve_thinking/2` returns:

  - `nil` - send nothing: thinking wasn't requested, the model doesn't
    reason, or it was switched off on a model that can't be switched off
  - `:off` - switch thinking off
  - a map - on, with:
    - `:level` - the requested Omni level, or the level a requested
      budget maps to
    - `:effort` - the model's effort value for that level, or `nil` when
      the model lists no effort values
    - `:budget` - a token budget, or `nil` when the model takes none. Set
      when the model has a budget range, or no thinking data at all.

  On a model with no thinking data (`thinking: true`), `:effort` is `nil`
  and `:budget` is set; dialects fall back to their plain encoding of
  `:level`.

  ## Implementing a text dialect

  Dialects are stateless and pure: every callback receives inputs that are
  already validated and returns plain data. No HTTP, no configuration, no
  side effects.

  ```elixir
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
  ```
  """

  alias Omni.{Context, Message, Model}

  @ladder ~w(minimal low medium high xhigh max)
  @budgets %{low: 1024, medium: 4096, high: 16_384, xhigh: 24_576, max: 32_768}

  @typedoc "An Omni thinking level."
  @type thinking_level :: :low | :medium | :high | :xhigh | :max

  @typedoc "What a dialect should send for the `:thinking` option."
  @type thinking ::
          nil
          | :off
          | %{
              level: thinking_level(),
              effort: String.t() | nil,
              budget: non_neg_integer() | nil
            }

  @doc """
  Returns a Peri schema map for dialect-specific options.

  The returned schema is merged with Omni's universal option schema (which
  covers `:max_tokens`, `:temperature`, `:cache`, `:thinking`, etc.) and
  validated in a single pass before any other callback runs. Use this to
  declare options unique to the API format, such as required parameters with
  defaults:

  ```elixir
  def option_schema do
    %{max_tokens: {:integer, {:default, 4096}}}
  end
  ```

  Return an empty map if the dialect has no additional options.
  """
  @callback option_schema() :: Peri.map_schema()

  @doc """
  Returns the URL path for the given model and options.

  The path is the API's resource path, appended to the base URL of the
  provider's endpoint for the dialect. The base URL carries any version
  segment (`https://api.openai.com/v1`), so the path does not. Most dialects
  return a static path:

  ```elixir
  def handle_path(_model, _opts), do: "/chat/completions"
  ```

  Some APIs put the model id in the path (Gemini uses
  `/models/{model}:streamGenerateContent`).
  """
  @callback handle_path(Model.t(), map()) :: String.t()

  @doc """
  Builds the request body from a model, context, and validated options.

  This is where Omni types become the API's own JSON: messages are
  reshaped, content blocks and tools encoded, and options mapped to API
  parameters. The options are already validated and include defaults, so
  no fallback values are needed.

  Always set `"stream" => true` (or the equivalent for the API format).

  Read the provider's compat flags with `Omni.Dialect.compat/2`. The
  returned map may be further adjusted by the provider module's
  `c:Omni.Provider.modify_body/4` before being sent as JSON.
  """
  @callback handle_body(Model.t(), Context.t(), map()) :: map()

  @doc """
  Parses a single decoded stream event into a list of delta tuples.

  Receives one JSON-decoded event from the stream, and the model the
  request was made with (for its compat flags). Returns a list of delta
  tuples (see [Delta types](#module-delta-types)). Most deltas are
  `{type, map}` pairs; `:error` is `{:error, reason}` with a bare term.
  Return `[]` to skip an event the dialect has no use for.

  The function must be stateless and pure: it receives one event and
  returns deltas with no knowledge of earlier events. That makes a dialect
  easy to test: pass a JSON map, assert the tuples that come out.
  """
  @callback handle_event(event :: map(), Model.t()) :: [{atom(), map() | term()}]

  @doc """
  Finishes the assembled assistant message once a stream completes.

  Optional. Called once, on the message of the `:done` response, after every
  event has been folded in. Use it for work that needs the whole stream
  rather than one event, such as merging replay data captured in fragments
  into the shape the API takes back. Not called when a stream ends in an
  error or is cancelled. Without it, the message is used as assembled.

  ```elixir
  def handle_message(%Message{private: %{chunks: chunks}} = message, _model) do
    %{message | private: %{message.private | chunks: merge(chunks)}}
  end
  ```
  """
  @callback handle_message(Message.t(), Model.t()) :: Message.t()

  @optional_callbacks handle_message: 2

  @doc """
  Resolves a `:thinking` option value for a model. See "Thinking" above.

  ```elixir
  model = %Omni.Model{id: "gpt-oss", name: "gpt-oss", thinking: %{efforts: ["low", "medium", "high"]}}
  Omni.Dialect.Text.resolve_thinking(model, :max)
  #=> %{level: :max, effort: "high", budget: nil}
  ```
  """
  @spec resolve_thinking(Model.t(), term()) :: thinking()
  def resolve_thinking(%Model{thinking: false}, _option), do: nil
  def resolve_thinking(_model, nil), do: nil
  def resolve_thinking(model, false), do: if(switchable?(model), do: :off)
  def resolve_thinking(model, level) when is_atom(level), do: thinking_on(model, level, nil)

  def resolve_thinking(model, budget) when is_integer(budget),
    do: thinking_on(model, budget_level(budget), budget)

  @doc """
  Returns the default budget for a thinking level, clamped to the model's
  budget range.
  """
  @spec thinking_budget(Model.t(), thinking_level()) :: non_neg_integer()
  def thinking_budget(%Model{} = model, level),
    do: clamp_budget(model, Map.fetch!(@budgets, level))

  # A model can be switched off when it has a toggle, lists "none", or
  # carries no data to say otherwise.
  defp switchable?(%Model{thinking: true}), do: true

  defp switchable?(%Model{thinking: thinking}) do
    Map.get(thinking, :toggle, false) or "none" in Map.get(thinking, :efforts, [])
  end

  defp thinking_on(%Model{thinking: thinking} = model, level, budget) do
    %{
      level: level,
      effort: effort(thinking, level),
      budget: if(budget?(thinking), do: clamp_budget(model, budget || @budgets[level]))
    }
  end

  # The smallest level whose budget covers the given one, else :max.
  defp budget_level(budget) do
    Enum.find([:low, :medium, :high, :xhigh], :max, &(@budgets[&1] >= budget))
  end

  defp budget?(true), do: true
  defp budget?(thinking), do: Map.has_key?(thinking, :budget)

  defp effort(true, _level), do: nil

  defp effort(thinking, level) do
    case Map.get(thinking, :efforts) do
      nil -> nil
      efforts -> clamp_effort(efforts, Atom.to_string(level))
    end
  end

  defp clamp_effort(efforts, level) do
    case Enum.filter(@ladder, &(&1 in efforts)) do
      [] ->
        if "default" in efforts, do: "default"

      supported ->
        index = Enum.find_index(@ladder, &(&1 == level))

        Enum.find(supported, &(ladder_index(&1) >= index)) || List.last(supported)
    end
  end

  defp ladder_index(value), do: Enum.find_index(@ladder, &(&1 == value))

  defp clamp_budget(%Model{thinking: %{budget: {min, max}}}, budget) do
    budget
    |> then(&if(is_integer(min), do: max(&1, min), else: &1))
    |> then(&if(is_integer(max), do: min(&1, max), else: &1))
  end

  defp clamp_budget(_model, budget), do: budget
end
