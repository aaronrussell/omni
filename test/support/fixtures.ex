defmodule Omni.Test.Fixtures do
  @moduledoc false

  # Builders for provider and model structs in unit tests, so tests don't
  # depend on what the catalog loaded at boot.

  alias Omni.{Model, Provider}
  alias Omni.Provider.Endpoint

  @base_url "https://api.test.com/v1"

  @doc """
  A provider struct with test defaults; `attrs` override. `:dialect` (default
  `Omni.Dialects.OpenAICompletions`) gets an endpoint at `:base_url` with
  `:compat`, unless `:dialects` is given.
  """
  def provider(attrs \\ []) do
    attrs = Map.new(attrs)
    {dialect, attrs} = Map.pop(attrs, :dialect, Omni.Dialects.OpenAICompletions)
    {base_url, attrs} = Map.pop(attrs, :base_url, @base_url)
    {compat, attrs} = Map.pop(attrs, :compat, %{})

    struct!(
      %Provider{
        id: :test,
        name: "Test",
        api_key: "test-key",
        auth: :dialect,
        dialects: %{dialect => %Endpoint{base_url: base_url, compat: Map.new(compat)}}
      },
      attrs
    )
  end

  @doc """
  A model struct. `:dialect` sets the dialect, for `:capability` (default
  `:text`); `:provider` takes provider attrs or a struct. Other attrs are
  model fields.
  """
  def model(attrs) do
    attrs = Map.new(attrs)
    {dialect, attrs} = Map.pop(attrs, :dialect, Omni.Dialects.OpenAICompletions)
    {capability, attrs} = Map.pop(attrs, :capability, :text)

    provider =
      case Map.get(attrs, :provider) do
        %Provider{} = provider ->
          provider

        provider_attrs ->
          provider(Map.put(Map.new(provider_attrs || %{}), :dialect, dialect))
      end

    attrs
    |> Map.put(:provider, provider)
    |> Map.put(:dialects, %{capability => dialect})
    |> Map.put_new(:name, attrs[:id])
    |> Model.new()
  end

  @doc """
  Loads a throwaway custom provider under a unique id and returns the id.
  Model ids given as strings speak Completions. Unloaded when the calling
  test exits.
  """
  def load_provider(opts \\ []) do
    id = :"test_provider_#{System.unique_integer([:positive])}"

    opts =
      Keyword.update(opts, :models, [], fn models ->
        Enum.map(models, fn
          model_id when is_binary(model_id) ->
            [id: model_id, dialects: %{text: Omni.Dialects.OpenAICompletions}]

          attrs ->
            attrs
        end)
      end)

    Provider.load([
      {id,
       Keyword.merge(
         [dialects: %{Omni.Dialects.OpenAICompletions => [base_url: @base_url]}],
         opts
       )}
    ])

    ExUnit.Callbacks.on_exit(fn -> unload(id) end)
    id
  end

  @doc "Removes a provider and its models from the store."
  def unload(id), do: Omni.Provider.Loader.unload(id)
end
