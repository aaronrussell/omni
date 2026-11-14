defmodule Omni.Provider.Builtins do
  @moduledoc false

  # The built-in providers, as a map of id to provider module.
  #
  # `:builtins` in `config :omni, :models, providers:` expands to these ids,
  # and a provider loading under one of them gets its module from here unless
  # config names another.

  @modules %{
    alibaba: Omni.Providers.Alibaba,
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    groq: Omni.Providers.Groq,
    mistral: Omni.Providers.Mistral,
    moonshotai: Omni.Providers.Moonshot,
    nearai: Omni.Providers.NearAI,
    ollama: Omni.Providers.Ollama,
    ollama_cloud: Omni.Providers.OllamaCloud,
    openai: Omni.Providers.OpenAI,
    opencode: Omni.Providers.OpenCode,
    openrouter: Omni.Providers.OpenRouter,
    togetherai: Omni.Providers.Together,
    typesafe: Omni.Providers.TypeSafe,
    venice: Omni.Providers.Venice,
    xai: Omni.Providers.XAI,
    zai: Omni.Providers.Zai
  }

  @doc "Returns the built-in provider ids, sorted."
  @spec ids() :: [atom()]
  def ids, do: @modules |> Map.keys() |> Enum.sort()

  @doc "Returns the provider module for a built-in id, or `nil`."
  @spec module(atom()) :: module() | nil
  def module(id), do: Map.get(@modules, id)

  @doc "Returns the built-in id a provider module is mapped to, or `nil`."
  @spec id_for(module()) :: atom() | nil
  def id_for(module) do
    Enum.find_value(@modules, fn {id, mod} -> if mod == module, do: id end)
  end
end
