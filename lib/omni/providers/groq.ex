defmodule Omni.Providers.Groq do
  @moduledoc """
  Provider for the Groq API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Reads the API key from the `GROQ_API_KEY` environment variable — no further
  configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, :providers,
        groq: [api_key: {:system, "MY_GROQ_KEY"}]

  Any provider key can be overridden — see `Omni.Provider`.

  ## Reasoning

  The `:thinking` option is supported. Accepted effort levels vary by model
  family; each level is rounded to the nearest the model supports, so
  `:xhigh` and `:max` may become the model's highest level. Reasoning always
  arrives separately from the answer: gpt-oss models return it that way, and
  other reasoning models (such as Qwen) are asked for it with
  `reasoning_format: "parsed"`, since Groq's default inlines it as
  `<think>` tags in the answer.
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
