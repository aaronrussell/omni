defmodule Mix.Tasks.Omni.Snapshot do
  @moduledoc false

  # Writes the models.dev catalog's chat and decision models to
  # `priv/models/models_dev.json`.
  #
  #     mix omni.snapshot
  #
  # A maintainer task, so it has no `@shortdoc` and stays out of `mix help`.
  #
  # The snapshot is the API response for `api.json?type=chat,decision`: every
  # provider, untransformed. The query leaves out the catalog's other model
  # types (image, embedding, speech, realtime, ...), which Omni can't call.
  # `Omni.Sources.ModelsDev` builds models from it at load time. Keeping it
  # unpruned lets any models.dev provider load, not only the built-ins.
  #
  # Only the encoding is normalised: pretty-printed, with keys sorted at
  # every level, so successive snapshots give small, reviewable diffs.
  #
  # The snapshot is checked in and shipped in the package. After a refresh,
  # update the golden test (test/omni/sources/models_dev_golden_test.exs).

  use Mix.Task

  @api_url "https://models.dev/api.json?type=chat,decision"
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

  The same data always produces the same bytes, whatever key order
  models.dev returned.
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
