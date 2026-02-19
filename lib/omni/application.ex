defmodule Omni.Application do
  @moduledoc false

  use Application

  @builtin_providers %{
    anthropic: Omni.Providers.Anthropic,
    google: Omni.Providers.Google,
    openai: Omni.Providers.OpenAI
  }

  @default_providers [:anthropic, :google, :openai]

  @impl true
  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    providers = Application.get_env(:omni, :providers, @default_providers)

    for {provider_id, provider_mod} <- Enum.map(providers, &normalize_provider/1) do
      model_map = Map.new(provider_mod.models(), &{&1.id, &1})
      :persistent_term.put({Omni, provider_id}, model_map)
    end
  end

  defp normalize_provider({_id, _mod} = pair), do: pair

  defp normalize_provider(id) when is_atom(id) do
    case @builtin_providers[id] do
      nil ->
        raise ArgumentError,
              "unknown built-in provider #{inspect(id)} — " <>
                "use {id, module} for custom providers"

      module ->
        {id, module}
    end
  end
end
