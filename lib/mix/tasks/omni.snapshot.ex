defmodule Mix.Tasks.Omni.Snapshot do
  @shortdoc "Captures a verbatim models.dev snapshot"

  @moduledoc """
  Fetches the full models.dev catalog and writes it verbatim to
  `priv/models/models_dev.json`.

      mix omni.snapshot

  The snapshot is the raw API response — all providers, no transformation, no
  filtering. `Omni.Sources.ModelsDev` transforms it into `%Omni.Model{}`
  structs at load time; keeping the snapshot unpruned lets custom providers
  point at any models.dev catalog, not just Omni's built-ins.

  This is a maintainer task: the snapshot is checked into the repo and shipped
  in the package. Run it manually when model data needs refreshing, and update
  the golden test expectations alongside the new snapshot.
  """

  use Mix.Task

  @api_url "https://models.dev/api.json"
  @snapshot_file "priv/models/models_dev.json"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    case Req.get(@api_url, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        File.mkdir_p!(Path.dirname(@snapshot_file))
        File.write!(@snapshot_file, body)
        Mix.shell().info("wrote #{byte_size(body)} bytes to #{@snapshot_file}")

      {:ok, %{status: status}} ->
        Mix.raise("models.dev returned HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Failed to fetch models.dev: #{inspect(reason)}")
    end
  end
end
