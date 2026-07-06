defmodule Mix.Tasks.Omni.Snapshot do
  @shortdoc "Captures a models.dev snapshot"

  @moduledoc """
  Fetches the full models.dev catalog and writes it to
  `priv/models/models_dev.json`.

      mix omni.snapshot

  The snapshot content is the raw API response — all providers, no
  transformation, no filtering. `Omni.Sources.ModelsDev` transforms it into
  `%Omni.Model{}` structs at load time; keeping the snapshot unpruned lets
  custom providers point at any models.dev catalog, not just Omni's built-ins.

  Only the encoding is normalized: pretty-printed with keys sorted at every
  level, so successive snapshots produce minimal, reviewable git diffs.

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
        json = body |> Jason.decode!() |> format()
        File.mkdir_p!(Path.dirname(@snapshot_file))
        File.write!(@snapshot_file, json)
        Mix.shell().info("wrote #{byte_size(json)} bytes to #{@snapshot_file}")

      {:ok, %{status: status}} ->
        Mix.raise("models.dev returned HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Failed to fetch models.dev: #{inspect(reason)}")
    end
  end

  @doc """
  Encodes decoded catalog data as pretty-printed JSON with sorted keys.

  Deterministic: the same data always produces the same bytes, regardless of
  the key order models.dev returned.
  """
  @spec format(term()) :: String.t()
  def format(data) do
    Jason.encode!(sort_keys(data), pretty: true) <> "\n"
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other
end
