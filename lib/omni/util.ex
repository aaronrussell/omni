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
end
