defmodule Omni.Providers.OpenAI do
  @moduledoc false

  # The built-in `:openai` provider: the OpenAI API, over Responses for text and
  # the Decisions API for decisions.
  #
  # `gpt-6-luna` serves text and decisions under one model id. The catalog lists
  # it as a chat model only, so `models/2` adds the decision dialect. A catalog
  # without the model gets no decision model.
  #
  # Users read about it in the "OpenAI" section of guides/built-in-providers.md.
  # Keep that in step with this module.

  @behaviour Omni.Provider

  # Models that serve OpenAI's Decisions API on the same id as their chat
  # model, which no catalog can express yet.
  @decision_models ["gpt-6-luna"]

  @impl true
  def config do
    [
      api_key: {:system, "OPENAI_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAIResponses => [base_url: "https://api.openai.com/v1"],
        Omni.Dialects.OpenAIDecisions => [base_url: "https://api.openai.com/v1"]
      }
    ]
  end

  @impl true
  def models(models, _provider) do
    Enum.map(models, fn
      %{id: id} = model when id in @decision_models ->
        %{model | dialects: Map.put(model.dialects, :decision, Omni.Dialects.OpenAIDecisions)}

      model ->
        model
    end)
  end
end
