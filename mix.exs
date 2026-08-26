defmodule Omni.MixProject do
  use Mix.Project

  @version "1.6.3"
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
      {:peri, "~> 0.8"},
      {:req, "~> 0.5"},

      # dev dependencies
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
      {:plug, "~> 1.0", only: :test}
    ] ++ llm_db_dep()
  end

  # OMNI_SKIP_LLMDB=1 excludes the optional llm_db dep so CI can verify Omni
  # compiles and tests green without it. Beware locally: a `mix deps.get` run
  # with it set can rewrite mix.lock without the llm_db entry.
  defp llm_db_dep do
    if System.get_env("OMNI_SKIP_LLMDB") do
      []
    else
      [{:llm_db, "~> 2026.7", optional: true}]
    end
  end

  defp docs do
    [
      main: "Omni",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      extras: ["CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        Data: [
          ~r/Omni\.Content\..+$/,
          Omni.Context,
          Omni.Message,
          Omni.Response,
          Omni.Usage
        ],
        Providers: ~r/^Omni\.Provider/,
        Dialects: ~r/^Omni\.Dialect/,
        Sources: ~r/^Omni\.Source/
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
      description:
        "Universal Elixir client for LLM APIs. Streaming text generation, tool use, and structured output.",
      licenses: ["Apache-2.0"],
      maintainers: ["Aaron Russell"],
      files: ~w(lib priv/models .formatter.exs mix.exs CHANGELOG.md LICENSE README.md),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
