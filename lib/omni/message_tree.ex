defmodule Omni.MessageTree do
  @moduledoc """
  A tree of conversation turns with a cursor pointing to the active path.

  Each turn has a unique integer ID, a parent pointer, a list of messages, and
  a usage struct. Multiple turns can share the same parent — this is how
  branching (regeneration, forking) works.

  The tree supports three core operations: pushing new turns, navigating to any
  turn in the tree, and querying the active path for messages and usage.

  ## Enumerable

  Iterating over a `MessageTree` yields `{id, turn}` tuples for each turn in
  the **active path**, in order. Use `tree.turns` to access the full tree
  including inactive branches.
  """

  alias Omni.{Message, Turn, Usage}

  @typedoc "A tree of conversation turns with an active path cursor."
  @type t :: %__MODULE__{
          turns: %{Turn.id() => Turn.t()},
          active_path: [Turn.id()]
        }

  defstruct turns: %{}, active_path: []

  # Query

  @doc "Returns a flat list of all messages along the active path, in order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{turns: turns, active_path: path}) do
    Enum.flat_map(path, fn id -> turns[id].messages end)
  end

  @doc "Returns the cumulative usage across all turns in the tree."
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{turns: turns}) do
    Map.values(turns) |> Enum.map(& &1.usage) |> Usage.sum()
  end

  @doc "Returns the number of turns in the active path."
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{active_path: path}), do: length(path)

  @doc "Returns the ID of the last turn in the active path, or `nil` if empty."
  @spec head(t()) :: Turn.id() | nil
  def head(%__MODULE__{active_path: []}), do: nil
  def head(%__MODULE__{active_path: path}), do: List.last(path)

  @doc "Returns the turn data for a given ID, or `nil` if not found."
  @spec get_turn(t(), Turn.id()) :: Turn.t() | nil
  def get_turn(%__MODULE__{turns: turns}, id), do: Map.get(turns, id)

  # Mutate

  @doc """
  Creates a new turn and appends it to the active path.

  The new turn's parent is the current `head/1` (or `nil` if the tree is
  empty). Returns `{turn, updated_tree}`.
  """
  @spec push(t(), [Message.t()], Usage.t()) :: {Turn.t(), t()}
  def push(%__MODULE__{turns: turns, active_path: path} = tree, messages, %Usage{} = usage) do
    id = map_size(turns)

    turn = Turn.new(id: id, parent: head(tree), messages: messages, usage: usage)
    turns = Map.put(turns, id, turn)

    {turn, %{tree | turns: turns, active_path: path ++ [id]}}
  end

  @doc """
  Sets the active path by walking parent pointers from `turn_id` back to root.

  Returns `{:error, :not_found}` if the turn ID doesn't exist in the tree.
  """
  @spec navigate(t(), Turn.id()) :: {:ok, t()} | {:error, :not_found}
  def navigate(%__MODULE__{turns: turns} = tree, turn_id) do
    case walk_to_root(turns, turn_id) do
      {:ok, path} -> {:ok, %{tree | active_path: path}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resets the active path to `[]` but preserves all turns.

  A subsequent `push/3` starts a new root turn (`parent: nil`).
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = tree), do: %{tree | active_path: []}

  # Introspect

  @doc "Returns the IDs of all turns whose parent is the given turn."
  @spec children(t(), Turn.id()) :: [Turn.id()]
  def children(%__MODULE__{turns: turns}, turn_id) do
    turns
    |> Enum.filter(fn {_id, turn} -> turn.parent == turn_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Returns other children of the same parent, excluding the given turn."
  @spec siblings(t(), Turn.id()) :: [Turn.id()]
  def siblings(%__MODULE__{turns: turns} = tree, turn_id) do
    case Map.get(turns, turn_id) do
      nil ->
        []

      %Turn{parent: nil} ->
        roots(tree) -- [turn_id]

      %Turn{parent: parent_id} ->
        children(tree, parent_id) -- [turn_id]
    end
  end

  @doc """
  Walks parent pointers from `turn_id` to root, returns the path in root-first order.

  Useful for UIs that need to show the full path to a specific branch point.
  """
  @spec path_to(t(), Turn.id()) :: {:ok, [Turn.id()]} | {:error, :not_found}
  def path_to(%__MODULE__{turns: turns}, turn_id), do: walk_to_root(turns, turn_id)

  @doc "Returns IDs of all turns with `parent: nil`."
  @spec roots(t()) :: [Turn.id()]
  def roots(%__MODULE__{turns: turns}) do
    turns
    |> Enum.filter(fn {_id, turn} -> turn.parent == nil end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Internal

  defp walk_to_root(turns, id, acc \\ [])

  defp walk_to_root(turns, id, acc) do
    case Map.get(turns, id) do
      nil -> {:error, :not_found}
      %Turn{parent: nil} -> {:ok, [id | acc]}
      %Turn{parent: parent_id} -> walk_to_root(turns, parent_id, [id | acc])
    end
  end

  defimpl Enumerable do
    def reduce(tree, cmd, fun) do
      tree.active_path
      |> Enum.map(&{&1, tree.turns[&1]})
      |> Enumerable.List.reduce(cmd, fun)
    end

    def count(tree), do: {:ok, length(tree.active_path)}
    def member?(_tree, _element), do: {:error, __MODULE__}
    def slice(_tree), do: {:error, __MODULE__}
  end
end
