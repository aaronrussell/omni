defmodule Omni.MixProject do
  use Mix.Project

  @version "2.0.0"
  @source_url "https://github.com/aaronrussell/omni"

  def project do
    [
      app: :omni,
      name: "Omni",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      package: pkg()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Omni.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:peri, "~> 0.12"},
      {:req, "~> 0.5"},

      # dev dependencies
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
      {:plug, "~> 1.0", only: :test}
    ] ++ llm_db_dep()
  end

  # OMNI_SKIP_LLMDB=1 excludes the optional llm_db dep so CI can verify Omni
  # compiles and tests green without it. Beware locally: running `mix deps.get`
  # or `mix precommit` with it set can rewrite mix.lock without the llm_db
  # entry.
  defp llm_db_dep do
    if System.get_env("OMNI_SKIP_LLMDB") do
      []
    else
      [{:llm_db, "~> 2026.11", optional: true}]
    end
  end

  defp docs do
    [
      main: "getting-started",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      extras: [
        "CHANGELOG.md",
        "guides/upgrading-to-v2.md",
        "guides/getting-started.md",
        "guides/text-generation.md",
        "guides/decisions.md",
        "guides/providers-and-models.md",
        "guides/built-in-providers.md"
      ],
      groups_for_extras: [
        Guides: ~r/^guides\/(?!upgrading)/
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "guides/upgrading-to-v2.md"],
      groups_for_modules: [
        "Text generation": [
          Omni.Context,
          Omni.Message,
          Omni.Response,
          Omni.StreamingResponse,
          Omni.Tool,
          Omni.Tool.Runner,
          Omni.Schema,
          Omni.Schema.Adapter
        ],
        Content: ~r/^Omni\.Content\..+$/,
        Decisions: [
          Omni.Decision,
          Omni.Question,
          ~r/^Omni\.Question\..+$/,
          Omni.Answer,
          ~r/^Omni\.Answer\..+$/
        ],
        Providers: ~r/^Omni\.Provider/,
        Dialects: ~r/^Omni\.Dialect/,
        Sources: ~r/^Omni\.Source/
      ],
      groups_for_docs: [
        "Text generation": &(&1[:group] == :generation),
        Decisions: &(&1[:group] == :decisions),
        Models: &(&1[:group] == :models),
        Context: &(&1[:group] == :context)
      ]
    ]
  end

  defp pkg do
    [
      description:
        "Universal Elixir client for LLM APIs. Text generation, tool use, structured output and decisions across many providers.",
      licenses: ["Apache-2.0"],
      maintainers: ["Aaron Russell"],
      files:
        ~w(lib priv/models priv/verify .formatter.exs mix.exs CHANGELOG.md LICENSE README.md),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
