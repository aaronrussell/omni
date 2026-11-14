defmodule Omni.Providers.OpenCode do
  @moduledoc false

  # The built-in `:opencode` provider: OpenCode Zen, a gateway that serves each
  # model over its lab's own API.
  #
  # Each model's dialect and each dialect's URL come from the catalog, which
  # mounts the APIs under `https://opencode.ai/inference/`: `openai/v1`
  # (Completions and Responses), `anthropic/v1`, `google/v1beta` and
  # `systemone/v1`. Auth is `:dialect`, the default, so each request
  # authenticates as its dialect's home API does.
  #
  # On Completions, reasoning is sent back as `reasoning_content`, except to
  # Mistral models, which `modify_body/4` handles: the shape varies by model
  # within one dialect, which a compat flag can't express.
  #
  # Users read about it in the "OpenCode Zen" section of
  # guides/built-in-providers.md. Keep that in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "OPENCODE_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [compat: [thinking_replay_format: :reasoning_content]]
      }
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
