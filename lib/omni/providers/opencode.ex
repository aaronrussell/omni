defmodule Omni.Providers.OpenCode do
  @moduledoc """
  Provider for the OpenCode Zen API.

  Provider id `:opencode`. Reads the API key from `OPENCODE_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, opencode: [...]` (see `Omni.Provider`).

  Zen is a gateway to models from several labs through one service, and the
  wire format depends on the model: Claude models use
  `Omni.Dialects.AnthropicMessages`, GPT models use
  `Omni.Dialects.OpenAIResponses`, and so on. Each model's dialect comes from
  the catalog, and each request authenticates the way that dialect's home API
  does.

  ## Reasoning

  On Chat Completions models, earlier reasoning is sent back in the
  `reasoning_content` field of assistant messages. Mistral models (ids
  starting `mistral-`) take it as a leading thinking chunk in `content`
  instead, as on Mistral's own API: Zen passes Mistral's wire through. This
  is done in the module's `c:Omni.Provider.modify_body/4`, since the shape
  varies by model within one dialect.

  ## Compat flags

  Sets this `Omni.Dialects.OpenAICompletions` flag:

    * `thinking_replay_format: :reasoning_content`

  Compat flags for this provider must be keyed by dialect (see
  `Omni.Provider`).
  """

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      base_url: "https://opencode.ai/zen/v1",
      api_key: {:system, "OPENCODE_API_KEY"},
      compat: %{Omni.Dialects.OpenAICompletions => [thinking_replay_format: :reasoning_content]}
    ]
  end

  # Mistral rejects unknown fields on messages, so its reasoning moves from
  # `reasoning_content` into the shape `thinking_replay_format: :content_chunks`
  # gives it. Zen streams Mistral's thinking without signatures, so the field
  # loses nothing.
  @impl true
  def modify_body(%{"messages" => messages} = body, %Model{id: "mistral-" <> _}, _context, _opts) do
    %{body | "messages" => Enum.map(messages, &to_thinking_chunk/1)}
  end

  def modify_body(body, _model, _context, _opts), do: body

  defp to_thinking_chunk(%{"role" => "assistant", "reasoning_content" => reasoning} = msg) do
    thinking = %{"type" => "thinking", "thinking" => [%{"type" => "text", "text" => reasoning}]}

    text =
      case msg["content"] do
        text when is_binary(text) and text != "" -> [%{"type" => "text", "text" => text}]
        _ -> []
      end

    msg
    |> Map.delete("reasoning_content")
    |> Map.put("content", [thinking | text])
  end

  defp to_thinking_chunk(msg), do: msg
end
