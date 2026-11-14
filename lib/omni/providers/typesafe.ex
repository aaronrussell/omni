defmodule Omni.Providers.TypeSafe do
  @moduledoc false

  # The built-in `:typesafe` provider: TypeSafe's System One API. Decision
  # models only.
  #
  # models.dev has no TypeSafe entry, so `models/2` lists the models TypeSafe
  # documents. Models from the source (`Omni.Sources.LLMDB` carries TypeSafe)
  # and from config win by id.
  #
  # The model list also appears in the guide. Update both when TypeSafe releases
  # a model.
  #
  # Users read about it in the "TypeSafe" section of
  # guides/built-in-providers.md. Keep that in step with this module.

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
