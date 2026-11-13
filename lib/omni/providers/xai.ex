defmodule Omni.Providers.XAI do
  @moduledoc false

  # Provider for the xAI API, using the `Omni.Dialects.OpenAIResponses`
  # dialect.
  #
  # xAI also serves Chat Completions, as a legacy endpoint. Omni uses
  # Responses, xAI's preferred API and the only one that returns encrypted
  # reasoning, so every text model (and every config model that names no
  # dialect) is given the Responses dialect when the provider loads, in the
  # module's `models/2`. That runs after config `models:`
  # entries are merged, so a text dialect set in config is replaced too.
  # Decision-only models are left alone.
  #
  # Reasoning:
  #
  # `:thinking` is supported and sent as `reasoning.effort`, rounded to the
  # levels the model accepts. Most Grok models can't switch reasoning off, so
  # `thinking: false` sends nothing on them; models that list a `"none"`
  # effort (such as `grok-4.3`) are switched off.
  #
  # Models with no effort levels in their data (such as
  # `grok-4.20-0309-reasoning`) reason but reject `reasoning.effort` with any
  # value, `"none"` included, so `:thinking` is not sent to them. This is done
  # in the module's `modify_body/4`, not with a compat flag.
  #
  # Reasoning is sent back on later turns of a conversation as encrypted
  # content, which also keeps xAI's prompt cache warm.
  #
  # What users are told is the "xAI" section of guides/built-in-providers.md;
  # keep it in step with this module.

  @behaviour Omni.Provider

  alias Omni.Model

  @impl true
  def config do
    [
      api_key: {:system, "XAI_API_KEY"},
      dialects: %{Omni.Dialects.OpenAIResponses => [base_url: "https://api.x.ai/v1"]}
    ]
  end

  # Catalogs may describe xAI's Chat Completions endpoint (llm_db does); Omni
  # uses Responses, so every text model is re-stamped with its dialect. A
  # config model naming no dialect gets it too; decision-only models don't.
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
