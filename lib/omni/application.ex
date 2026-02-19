defmodule Omni.Application do
  @moduledoc false

  use Application

  @default_providers [:anthropic, :google, :openai]

  @impl true
  def start(_type, _args) do
    load_providers()
    Supervisor.start_link([], strategy: :one_for_one, name: Omni.Supervisor)
  end

  defp load_providers do
    providers = Application.get_env(:omni, :providers, @default_providers)
    Omni.Provider.load(providers)
  end
end
