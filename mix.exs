defmodule Omni.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/aaronrussell/omni"

  def project do
    [
      app: :omni,
      name: "Omni",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: pkg()
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

  defp docs do
    [
      main: "Omni",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: ["CHANGELOG.md"],
      groups_for_modules: [
        Agents: ~r/^Omni\.Agent/,
        Data: [
          ~r/Omni\.Content\..+$/,
          Omni.Context,
          Omni.Message,
          Omni.Response,
          Omni.Usage
        ],
        Providers: ~r/^Omni\.Provider/,
        Dialects: ~r/^Omni\.Dialect/
      ],
      groups_for_docs: [
        "Text Generation": &(&1[:group] == :generation),
        Models: &(&1[:group] == :models),
        Context: &(&1[:group] == :context)
      ]
    ]
  end

  defp pkg do
    [
      description: "Universal Elixir client for LLM APIs. Text generation, tool use, and agents.",
      licenses: ["Apache-2.0"],
      maintainers: ["Aaron Russell"],
      files: ~w(lib priv/models .formatter.exs mix.exs CHANGELOG.md LICENSE README.md),
      links: %{
        "GitHub" => "https://github.com/aaronrussell/omni"
      }
    ]
  end
end
