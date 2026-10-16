defmodule Omni.Util do
  @moduledoc false

  @doc """
  Puts `value` at `key` in `container` unless `value` is `nil`.

  Works with both maps (string or atom keys) and keyword lists.

      iex> maybe_put(%{}, "a", 1)
      %{"a" => 1}

      iex> maybe_put(%{}, "a", nil)
      %{}

      iex> maybe_put([], :a, 1)
      [a: 1]

      iex> maybe_put([], :a, nil)
      []
  """
  @spec maybe_put(map() | keyword(), term(), term()) :: map() | keyword()
  def maybe_put(container, _key, nil), do: container

  def maybe_put(container, key, value) when is_list(container),
    do: Keyword.put(container, key, value)

  def maybe_put(container, key, value) when is_map(container), do: Map.put(container, key, value)

  @doc """
  Merges `map_or_nil` into `container` unless it is `nil`.

  Works with both maps and keyword lists.

      iex> maybe_merge(%{"a" => 1}, %{"b" => 2})
      %{"a" => 1, "b" => 2}

      iex> maybe_merge(%{"a" => 1}, nil)
      %{"a" => 1}
  """
  @spec maybe_merge(map() | keyword(), map() | keyword() | nil) :: map() | keyword()
  def maybe_merge(container, nil), do: container

  def maybe_merge(container, other) when is_list(container) and is_list(other),
    do: Keyword.merge(container, other)

  def maybe_merge(container, other) when is_map(container) and is_map(other),
    do: Map.merge(container, other)

  @doc """
  Puts `value` at a dotted string `path` in `map` unless `value` is `nil`,
  creating or merging into nested maps.

      iex> put_path(%{}, "reasoning.effort", "high")
      %{"reasoning" => %{"effort" => "high"}}

      iex> put_path(%{"reasoning" => %{"enabled" => true}}, "reasoning.effort", "high")
      %{"reasoning" => %{"enabled" => true, "effort" => "high"}}

      iex> put_path(%{}, "max_tokens", nil)
      %{}
  """
  @spec put_path(map(), String.t(), term()) :: map()
  def put_path(map, _path, nil), do: map
  def put_path(map, path, value), do: do_put_path(map, String.split(path, "."), value)

  defp do_put_path(map, [key], value), do: Map.put(map, key, value)

  defp do_put_path(map, [key | rest], value) do
    inner =
      case Map.get(map, key) do
        %{} = inner -> inner
        _ -> %{}
      end

    Map.put(map, key, do_put_path(inner, rest, value))
  end
end
