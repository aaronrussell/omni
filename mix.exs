defmodule Omni.MixProject do
  use Mix.Project

  def project do
    [
      app: :omni,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Omni.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:peri, "~> 0.6.2"},
      {:req, "~> 0.5.17"},
    ]
  end
end
