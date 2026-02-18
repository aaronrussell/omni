defmodule Omni do
  @moduledoc """
  Elixir library for interacting with LLM APIs across multiple providers.
  """

  @doc "Looks up a model by provider ID and model ID from `:persistent_term`."
  defdelegate get_model(provider_id, model_id), to: Omni.Model, as: :get

  @doc "Returns all models for a provider, or an error if the provider is unknown."
  defdelegate list_models(provider_id), to: Omni.Model, as: :list

  @doc "Creates a new `%Omni.Tool{}` from a keyword list or map."
  defdelegate tool(attrs), to: Omni.Tool, as: :new

  @doc "Creates a new `%Omni.Context{}` from a string, list of messages, keyword list, or map."
  defdelegate context(input), to: Omni.Context, as: :new

  @doc "Creates a new `%Omni.Message{}` from a string, keyword list, or map."
  defdelegate message(input), to: Omni.Message, as: :new
end
