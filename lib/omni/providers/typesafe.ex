defmodule Omni.Providers.TypeSafe do
  @moduledoc """
  Provider for TypeSafe's System One API, using the `Omni.Dialects.TypeSafeSystemOne`
  dialect.

  Provider id `:typesafe`. Reads the API key from `TYPESAFE_API_KEY`, so no
  configuration is needed if it is set. Override any setting under
  `config :omni, :providers, typesafe: [...]` (see `Omni.Provider`).

  TypeSafe serves decision models only: use them with `Omni.decide/3`.

      {:ok, decision} = Omni.decide({:typesafe, "jev-latest"}, {"I was charged twice", [
        refund: Omni.predicate("Is the customer asking for a refund?")
      ]})

  ## Models

  models.dev has no TypeSafe entry, so the module lists TypeSafe's models
  itself: `jev-1.14.0`, `jev-1.13.0`, and the aliases `jev-latest` and
  `jev-preview`, as TypeSafe documents them. Models from the source
  (`Omni.Sources.LLMDB` carries TypeSafe) and from config take precedence
  by id; the module's list fills in the rest. A new release is a config
  entry away:

      config :omni, :providers,
        typesafe: [
          models: [
            [id: "jev-1.15.0", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}, input_cost: 0.042]
          ]
        ]

  Requests use TypeSafe's default context limits (64k tokens per request).
  Its long-context mode is switched on per request with a header:

      Omni.decide(model, decision, headers: %{"TypeSafe-Danger-Zone-Long-Context" => "true"})
  """

  @behaviour Omni.Provider

  alias Omni.Model

  # From https://docs.typesafe.ai/models.md (2026-11-03). Priced per input
  # token; output is free.
  @models [
    {"jev-1.14.0", "Jev 1.14", ~D[2026-10-14]},
    {"jev-1.13.0", "Jev 1.13", ~D[2026-09-15]},
    {"jev-latest", "Jev (latest)", ~D[2026-10-14]},
    {"jev-preview", "Jev (preview)", ~D[2026-10-14]}
  ]

  @impl true
  def config do
    [
      api_key: {:system, "TYPESAFE_API_KEY"},
      dialects: %{Omni.Dialects.TypeSafeSystemOne => [base_url: "https://api.typesafe.ai/v1"]}
    ]
  end

  # The documented models fill in ids the source and config don't have.
  # Config entries are merged in before this runs, so returning the list
  # only when given none would drop it as soon as config adds a model.
  @impl true
  def models(models, _provider) do
    ids = MapSet.new(models, & &1.id)

    documented =
      for {id, name, release_date} <- @models, not MapSet.member?(ids, id) do
        Model.new(
          id: id,
          name: name,
          release_date: release_date,
          dialects: %{decision: Omni.Dialects.TypeSafeSystemOne},
          context_size: 64_000,
          input_cost: 0.042
        )
      end

    models ++ documented
  end
end
