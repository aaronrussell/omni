defmodule Omni.Providers.XAI do
  @moduledoc false

  # The built-in `:xai` provider: the xAI API, over Responses.
  #
  # - xAI also serves Chat Completions, as a legacy endpoint. Responses is the
  #   only one that returns encrypted reasoning, so `models/2` moves every text
  #   model to it. Sending that reasoning back also keeps xAI's prompt cache
  #   warm.
  # - Most Grok models can't switch reasoning off: they list no `"none"` effort,
  #   so the dialect sends nothing for `thinking: false`.
  # - Models with no effort levels in their data reject `reasoning.effort`
  #   outright, which `modify_body/4` handles.
  #
  # Users read about it in the "xAI" section of guides/built-in-providers.md.
  # Keep that in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "XAI_API_KEY"},
      dialects: %{Omni.Dialects.OpenAIResponses => [base_url: "https://api.x.ai/v1"]}
    ]
  end

  # Catalogs may describe xAI's Chat Completions endpoint (llm_db does).
  # Gives every text model the Responses dialect, and every config model that
  # names no dialect. Decision-only models are left alone. This runs after
  # config `models:` entries are merged, so a text dialect set in config is
  # replaced too.
  @impl true
  def models(models, _provider) do
    Enum.map(models, fn model ->
      if Model.capability?(model, :text) or model.dialects == %{},
        do: %{model | dialects: Map.put(model.dialects, :text, Omni.Dialects.OpenAIResponses)},
        else: model
    end)
  end

  # Models with no effort data reject `reasoning.effort` outright ("does not
  # support parameter reasoningEffort"), so the dialect's `"none"` for off
  # and its plain level for on both fail. They reason regardless.
  @impl true
  def modify_body(body, %Model{thinking: true}, _context, _opts),
    do: Map.delete(body, "reasoning")

  def modify_body(body, _model, _context, _opts), do: body
end
