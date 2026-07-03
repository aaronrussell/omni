defmodule Omni.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    case Application.fetch_env(:omni, :providers) do
      {:ok, legacy} -> raise ArgumentError, Omni.Provider.config_migration_message(legacy)
      :error -> :ok
    end

    :omni
    |> Application.get_env(:models)
    |> Omni.Provider.providers_from_config()
    |> Omni.Provider.load()
  end
end
