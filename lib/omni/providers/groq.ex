defmodule Omni.Providers.Groq do
  @moduledoc false

  # Provider for the Groq API, using the `Omni.Dialects.OpenAICompletions`
  # dialect.
  #
  # Reasoning:
  #
  # `:thinking` is supported. Accepted effort levels vary by model family, and
  # each level is rounded to the nearest the model supports, so `:xhigh` and
  # `:max` may become the model's highest level.
  #
  # Reasoning always arrives separately from the answer. gpt-oss models return
  # it that way; other reasoning models (such as Qwen) are asked for it with
  # `reasoning_format: "parsed"`, because Groq's default puts it in the answer
  # as `<think>` tags. This is done in the module's `modify_body/4`,
  # not with a compat flag, so `like: :groq` doesn't copy it.
  #
  # Earlier reasoning is sent back in the `reasoning` field of assistant
  # messages.
  #
  # What users are told is the "Groq" section of guides/built-in-providers.md;
  # keep it in step with this module.

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
