defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect for text and `Omni.Dialects.OpenAIDecisions` for decisions.

  Provider id `:openai`. Reads the API key from `OPENAI_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, openai: [...]` (see `Omni.Provider`).

  ## Decisions

  `gpt-6-luna` serves both text and decisions on the same model id. The
  catalog lists it as a chat model only, so the module adds the decision
  dialect when the provider loads, in its `c:Omni.Provider.models/2`; a
  catalog without the model gets no decision model.

      {:ok, decision} = Omni.decide({:openai, "gpt-6-luna"}, {"I was charged twice", [
        refund: Omni.predicate("Is the customer asking for a refund?")
      ]})
  """

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
