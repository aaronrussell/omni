defmodule Omni.Test.Fixtures do
  @moduledoc false

  # Builders for provider and model structs in unit tests, so tests don't
  # depend on what the catalog loaded at boot.

  alias Omni.{Model, Provider}

  @doc "A provider struct with test defaults; `attrs` override."
  def provider(attrs \\ []) do
    struct!(
      %Provider{
        id: :test,
        name: "Test",
        base_url: "https://api.test.com/v1",
        api_key: "test-key",
        auth: :dialect,
        tier: :custom
      },
      attrs
    )
  end

  @doc """
  A model struct. `:dialect` sets the text dialect; `:provider` takes provider
  attrs or a struct. Other attrs are model fields.
  """
  def model(attrs) do
    attrs = Map.new(attrs)
    {dialect, attrs} = Map.pop(attrs, :dialect, Omni.Dialects.OpenAICompletions)

    provider =
      case Map.get(attrs, :provider) do
        %Provider{} = provider ->
          provider

        provider_attrs ->
          provider(Map.to_list(provider_attrs || %{}) ++ [dialects: %{text: [dialect]}])
      end

    attrs
    |> Map.put(:provider, provider)
    |> Map.put(:dialects, %{text: dialect})
    |> Map.put_new(:name, attrs[:id])
    |> Model.new()
  end

  @doc """
  Loads a throwaway custom provider under a unique id and returns the id.
  Unloaded when the calling test exits.
  """
  def load_provider(opts \\ []) do
    id = :"test_provider_#{System.unique_integer([:positive])}"

    Provider.load([
      {id,
       Keyword.merge(
         [
           base_url: "https://api.test.com/v1",
           dialects: %{text: Omni.Dialects.OpenAICompletions}
         ],
         opts
       )}
    ])

    ExUnit.Callbacks.on_exit(fn -> unload(id) end)
    id
  end

  @doc "Removes a provider and its models from the store."
  def unload(id) do
    :persistent_term.erase(Provider.models_key(id))
    providers = :persistent_term.get(Provider.providers_key(), %{})
    :persistent_term.put(Provider.providers_key(), Map.delete(providers, id))
  end
end
