defmodule Omni.Dialect.Decision do
  @moduledoc """
  Behaviour for decision dialects.

  A decision dialect turns a `%Omni.Decision{}` (shared state plus typed
  questions) into one JSON request, and reads the JSON response back into
  answers and usage. There is no streaming: the whole response arrives at
  once. Declare it with `use Omni.Dialect, :decision`, which also sets the
  base `Omni.Dialect` behaviour (`c:Omni.Dialect.auth/0`,
  `c:Omni.Dialect.compat_schema/0`).

  ## Implementing a decision dialect

  Like text dialects, decision dialects are stateless and pure: no HTTP, no
  configuration, no side effects.

      defmodule MyApp.Dialects.CustomDecisions do
        use Omni.Dialect, :decision

        alias Omni.{Answer, Decision, Question, Usage}

        @impl true
        def option_schema, do: %{}

        @impl true
        def compat_schema, do: %{}

        @impl true
        def auth, do: :bearer

        @impl true
        def handle_path(_model, _opts), do: "/decide"

        @impl true
        def handle_body(model, %Decision{} = decision, _opts) do
          %{
            "model" => model.id,
            "input" => decision.state,
            "questions" => Enum.map(decision.questions, &encode_question/1)
          }
        end

        @impl true
        def handle_response(%{"answers" => answers} = body, %Decision{} = decision, _model) do
          with {:ok, answers} <- decode_answers(answers, decision.questions) do
            usage = Usage.new(input_tokens: body["usage"]["input_tokens"])
            {:ok, %{decision | answers: answers, usage: usage}}
          end
        end
      end
  """

  alias Omni.{Decision, Model}

  @doc """
  Returns a Peri schema map for dialect-specific options.

  The returned schema is merged with Omni's config options (`:api_key`,
  `:host`, `:headers`, `:timeout`, ...) and validated in a single pass. Text
  generation options such as `:max_tokens` are not part of a decision
  request. Return an empty map if the dialect has no options:

      def option_schema, do: %{safety_identifier: :string}
  """
  @callback option_schema() :: Peri.map_schema()

  @doc """
  Returns the URL path for the given model and options.

  The path is the API's resource path, appended to the base URL of the
  provider's endpoint for the dialect:

      def handle_path(_model, _opts), do: "/systemone"
  """
  @callback handle_path(Model.t(), map()) :: String.t()

  @doc """
  Builds the request body from a model, a decision, and validated options.

  The decision has been validated: it has at least one question, each with
  non-empty instructions, and every choice or score question has at least
  two options. Encode each question under a name the response can be matched
  back by. The returned map may be further adjusted by the provider module's
  `c:Omni.Provider.modify_body/4` before being sent as JSON.
  """
  @callback handle_body(Model.t(), Decision.t(), map()) :: map()

  @doc """
  Reads a decoded response body into the decision.

  Fills `:answers` (a keyword list aligned with `decision.questions`, one
  `Omni.Answer` struct per question) and `:usage` (an `%Omni.Usage{}` with
  token counts only; Omni computes costs from the model's pricing). Return
  `{:error, {:invalid_answer, name}}` when an answer is missing, unexpected,
  or of the wrong type for its question.
  """
  @callback handle_response(body :: map(), Decision.t(), Model.t()) ::
              {:ok, Decision.t()} | {:error, term()}
end
