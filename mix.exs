defmodule Omni.MixProject do
  use Mix.Project

  def project do
    [
      app: :omni,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false, warn_if_outdated: true},
      {:peri, "~> 0.6.2"},
      {:plug, "~> 1.0", only: :test},
      {:req, "~> 0.5.17"}
    ]
  end
end
