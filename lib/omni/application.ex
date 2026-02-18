defmodule Omni.Application do
  @moduledoc false

  use Application

  @default_providers [:anthropic]

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
    module = Module.concat(Omni.Providers, id |> to_string() |> Macro.camelize())

    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "unknown built-in provider #{inspect(id)} — module #{inspect(module)} does not exist"
    end

    {id, module}
  end
end
