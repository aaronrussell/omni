defmodule Omni.Dialect do
  @moduledoc """
  Behaviour for wire format translation between Omni types and provider APIs.

  A dialect handles the pure data transformation layer: building request
  bodies from Omni structs and reading what the API sends back. Each dialect
  corresponds to one API format (e.g. Anthropic Messages, OpenAI Chat
  Completions) and serves one capability:

    * `Omni.Dialect.Text` — text generation, streamed (`Omni.stream_text/3`)
    * `Omni.Dialect.Decision` — decisions: typed questions answered with
      probabilities (`Omni.decide/3`)

  This module is the base every dialect shares: how the home API
  authenticates (`c:auth/0`) and the compat flags it understands
  (`c:compat_schema/0`), plus the registry and `compat/2`. The capability
  behaviour adds the callbacks that build requests and read responses.

  Most custom integrations only need a new provider, not a new dialect —
  implement a dialect only when the provider speaks a wire format not covered
  by the existing modules. See `Omni.Provider` for the broader integration
  story and how providers and dialects compose.

  ## Available dialects

  Text:

    * `Omni.Dialects.OpenAICompletions` — OpenAI Chat Completions format, used
      by most third-party providers (Groq, Together, Fireworks, DeepSeek, etc.)
    * `Omni.Dialects.OpenAIResponses` — OpenAI's newer Responses API format
    * `Omni.Dialects.AnthropicMessages` — Anthropic Messages format
    * `Omni.Dialects.GoogleGenerateContent` — Gemini API `generateContent` format
    * `Omni.Dialects.OllamaChat` — Ollama native chat format (NDJSON streaming)

  Decision:

    * `Omni.Dialects.TypeSafeSystemOne` — TypeSafe's System One format, served by
      TypeSafe, OpenRouter, OpenCode Zen, Ollama and others
    * `Omni.Dialects.OpenAIDecisions` — OpenAI's Decisions API

  ## Dialect registry

  Built-in dialects are registered with string identifiers for use in model
  catalog data (e.g. `"anthropic_messages"`, `"typesafe_system_one"`). Use `get/1`
  or `get!/1` to resolve a string to its module. This is primarily used by
  model sources (see `Omni.Source.build_model/1`) when mapping catalog data
  to dialects.

  ## Compat flags

  Providers that speak a dialect with small deviations from its home API
  describe them as compat flags, which the dialect declares in
  `c:compat_schema/0` and reads with `compat/2` while it encodes. Flags are
  set per endpoint (see `Omni.Provider.Endpoint`) and validated against the
  schema when the provider loads. See
  `Omni.Dialects.OpenAICompletions` for the flags it understands.

  ## Implementing a dialect

  `use Omni.Dialect` with the capability the dialect serves. It declares
  both behaviours, this one and the capability's, and nothing more:

      defmodule MyApp.Dialects.CustomFormat do
        use Omni.Dialect, :text

        @impl true
        def auth, do: :bearer

        @impl true
        def compat_schema, do: %{}

        # ...and the callbacks of Omni.Dialect.Text
      end

  A dialect serves exactly one capability. A provider that serves two lists
  a dialect for each. See `Omni.Dialect.Text` and `Omni.Dialect.Decision`
  for the callbacks and full examples.
  """

  alias Omni.{Model, Provider}
  alias Omni.Provider.Endpoint

  @registry %{
    "anthropic_messages" => Omni.Dialects.AnthropicMessages,
    "openai_completions" => Omni.Dialects.OpenAICompletions,
    "openai_responses" => Omni.Dialects.OpenAIResponses,
    "google_generate_content" => Omni.Dialects.GoogleGenerateContent,
    "ollama_chat" => Omni.Dialects.OllamaChat,
    "typesafe_system_one" => Omni.Dialects.TypeSafeSystemOne,
    "openai_decisions" => Omni.Dialects.OpenAIDecisions
  }

  @capabilities %{text: Omni.Dialect.Text, decision: Omni.Dialect.Decision}

  @doc false
  defmacro __using__(capability) when capability in [:text, :decision] do
    behaviour = Map.fetch!(@capabilities, capability)

    quote do
      @behaviour Omni.Dialect
      @behaviour unquote(behaviour)
    end
  end

  defmacro __using__(other) do
    raise ArgumentError,
          "use Omni.Dialect expects a capability, :text or :decision — got: #{Macro.to_string(other)}"
  end

  @doc """
  Resolves a dialect string identifier to its module.

  Built-in dialect identifiers: `"anthropic_messages"`, `"openai_completions"`,
  `"openai_responses"`, `"google_generate_content"`, `"ollama_chat"`,
  `"typesafe_system_one"`, `"openai_decisions"`.
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

  Reads the flags of the provider's endpoint for the dialect, returning `%{}`
  when it sets none (or the model has no provider):

      compat = Omni.Dialect.compat(model, __MODULE__)
      field = Map.get(compat, :max_tokens_field, "max_completion_tokens")
  """
  @spec compat(Model.t(), module()) :: map()
  def compat(%Model{provider: %Provider{dialects: dialects}}, dialect) do
    case dialects do
      %{^dialect => %Endpoint{compat: compat}} -> compat
      _ -> %{}
    end
  end

  def compat(%Model{}, _dialect), do: %{}

  @doc """
  Returns the capability a dialect module serves, or `nil` for a module that
  is not a dialect.

  Read from the capability behaviour the module declares (see
  `use Omni.Dialect`):

      Omni.Dialect.capability(Omni.Dialects.AnthropicMessages)  #=> :text
      Omni.Dialect.capability(Omni.Dialects.TypeSafeSystemOne)  #=> :decision
  """
  @spec capability(module()) :: :text | :decision | nil
  def capability(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      behaviours =
        module.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      if __MODULE__ in behaviours do
        Enum.find_value(@capabilities, fn {capability, behaviour} ->
          if behaviour in behaviours, do: capability
        end)
      end
    end
  end

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
end
