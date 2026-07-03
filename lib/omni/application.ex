defmodule Omni.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    :omni
    |> Application.get_env(:providers)
    |> Omni.Provider.providers_from_config()
    |> Omni.Provider.load()
  end
end
