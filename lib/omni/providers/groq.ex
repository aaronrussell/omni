defmodule Omni.Providers.Groq do
  @moduledoc false

  # The built-in `:groq` provider: the Groq API, over Chat Completions.
  #
  # Reasoning is asked for apart from the answer in `modify_body/4`, not with a
  # compat flag, so `like: :groq` doesn't copy it.
  #
  # Users read about it in the "Groq" section of guides/built-in-providers.md.
  # Keep that in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "GROQ_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://api.groq.com/openai/v1",
          compat: [thinking_replay_format: :reasoning]
        ]
      }
    ]
  end

  # Groq's reasoning_format defaults to "raw" (<think> tags in the content)
  # on reasoning models other than gpt-oss, which doesn't support it and
  # returns reasoning separately anyway. Those models reason unless thinking
  # is switched off, so ask for parsed reasoning whenever it isn't.
  @impl true
  def modify_body(body, %Model{id: id, thinking: thinking}, _context, _opts) do
    if thinking != false and not String.starts_with?(id, "openai/gpt-oss") and
         body["reasoning_effort"] != "none",
       do: Map.put(body, "reasoning_format", "parsed"),
       else: body
  end
end
