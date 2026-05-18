defmodule Omni.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    builtins = Map.keys(Omni.Provider.builtin_providers())
    providers = Application.get_env(:omni, :providers) || builtins
    Omni.Provider.load(providers)
  end
end
