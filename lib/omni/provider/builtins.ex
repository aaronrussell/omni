defmodule Omni.Provider.Builtins do
  # The verified built-in providers: id → provider module. `:builtins` in
  # `config :omni, :models, providers:` expands to these ids, and a provider
  # loading under one of them gets its module from here unless config names
  # another.
  @moduledoc false

  @modules %{
    alibaba: Omni.Providers.Alibaba,
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    groq: Omni.Providers.Groq,
    moonshotai: Omni.Providers.Moonshot,
    nearai: Omni.Providers.NearAI,
    ollama: Omni.Providers.Ollama,
    ollama_cloud: Omni.Providers.OllamaCloud,
    openai: Omni.Providers.OpenAI,
    opencode: Omni.Providers.OpenCode,
    openrouter: Omni.Providers.OpenRouter,
    venice: Omni.Providers.Venice,
    zai: Omni.Providers.Zai
  }

  @spec ids() :: [atom()]
  def ids, do: @modules |> Map.keys() |> Enum.sort()

  @spec module(atom()) :: module() | nil
  def module(id), do: Map.get(@modules, id)

  @spec builtin?(atom()) :: boolean()
  def builtin?(id), do: Map.has_key?(@modules, id)

  @spec id_for(module()) :: atom() | nil
  def id_for(module) do
    Enum.find_value(@modules, fn {id, mod} -> if mod == module, do: id end)
  end
end
