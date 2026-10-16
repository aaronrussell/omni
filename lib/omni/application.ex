defmodule Omni.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Omni.Provider.Loader.boot()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end
end
