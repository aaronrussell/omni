defmodule Omni.Providers.XAI do
  @moduledoc """
  Provider for the xAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect.

  Provider id `:xai`. Reads the API key from `XAI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, xai: [...]` (see `Omni.Provider`).

  xAI also serves Chat Completions, as a legacy endpoint. Omni uses
  Responses, xAI's preferred API and the only one that returns encrypted
  reasoning, so every catalog model is given the Responses dialect when the
  provider loads.

  ## Reasoning

  `:thinking` is supported and sent as `reasoning.effort`, rounded to the
  levels the model accepts. Most Grok models can't switch reasoning off, so
  `thinking: false` sends nothing on them; models that list a `"none"`
  effort (such as `grok-4.3`) are switched off.

  Models with no effort levels in their data (such as
  `grok-4.20-0309-reasoning`) reason but reject `reasoning.effort` with any
  value, `"none"` included, so `:thinking` is not sent to them. This is done
  in the module's `c:Omni.Provider.modify_body/4`, not with a compat flag.

  Reasoning is sent back on later turns of a conversation as encrypted
  content, which also keeps xAI's prompt cache warm.
  """

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      base_url: "https://api.x.ai/v1",
      api_key: {:system, "XAI_API_KEY"},
      dialects: %{text: Omni.Dialects.OpenAIResponses}
    ]
  end

  # Catalogs may describe xAI's Chat Completions endpoint (llm_db does); Omni
  # uses Responses, so every model is re-stamped with its dialect.
  @impl true
  def models(models, _provider) do
    Enum.map(
      models,
      &%{&1 | dialects: Map.put(&1.dialects, :text, Omni.Dialects.OpenAIResponses)}
    )
  end

  # Models with no effort data reject `reasoning.effort` outright ("does not
  # support parameter reasoningEffort"), so the dialect's `"none"` for off
  # and its plain level for on both fail. They reason regardless.
  @impl true
  def modify_body(body, %Model{thinking: true}, _context, _opts),
    do: Map.delete(body, "reasoning")

  def modify_body(body, _model, _context, _opts), do: body
end
