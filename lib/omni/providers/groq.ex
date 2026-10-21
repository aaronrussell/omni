defmodule Omni.Providers.Groq do
  @moduledoc """
  Provider for the Groq API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Provider id `:groq`. Reads the API key from `GROQ_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, groq: [...]` (see `Omni.Provider`).

  ## Reasoning

  `:thinking` is supported. Accepted effort levels vary by model family, and
  each level is rounded to the nearest the model supports, so `:xhigh` and
  `:max` may become the model's highest level.

  Reasoning always arrives separately from the answer. gpt-oss models return
  it that way; other reasoning models (such as Qwen) are asked for it with
  `reasoning_format: "parsed"`, because Groq's default puts it in the answer
  as `<think>` tags. This is done in the module's `c:Omni.Provider.modify_body/4`,
  not with a compat flag, so `like: :groq` doesn't copy it.
  """

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [base_url: "https://api.groq.com/openai/v1", api_key: {:system, "GROQ_API_KEY"}]
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
