defmodule Omni.MessageTree do
  @moduledoc """
  A tree of conversation rounds with a cursor pointing to the active path.

  Each round has a unique integer ID, a parent pointer, a list of messages, and
  a usage struct. Multiple rounds can share the same parent — this is how
  branching (regeneration, forking) works.

  The tree supports three core operations: pushing new rounds, navigating to any
  round in the tree, and querying the active path for messages and usage.

  ## Enumerable

  Iterating over a `MessageTree` yields `{id, round}` tuples for each round in
  the **active path**, in order. Use `tree.rounds` to access the full tree
  including inactive branches.
  """

  alias Omni.{Message, Usage}

  @typedoc "Integer round identifier, assigned sequentially by `push/3`."
  @type round_id :: non_neg_integer()

  @typedoc "A single conversation round: parent pointer, messages, and usage."
  @type round :: %{
          parent: round_id() | nil,
          messages: [Message.t()],
          usage: Usage.t()
        }

  @typedoc "A tree of conversation rounds with an active path cursor."
  @type t :: %__MODULE__{
          rounds: %{round_id() => round()},
          active_path: [round_id()]
        }

  defstruct rounds: %{}, active_path: []

  # Query

  @doc "Returns a flat list of all messages along the active path, in order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{rounds: rounds, active_path: path}) do
    Enum.flat_map(path, fn id -> rounds[id].messages end)
  end

  @doc "Returns the cumulative usage across the active path."
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{rounds: rounds, active_path: path}) do
    path |> Enum.map(fn id -> rounds[id].usage end) |> Usage.sum()
  end

  @doc "Returns the number of rounds in the active path."
  @spec round_count(t()) :: non_neg_integer()
  def round_count(%__MODULE__{active_path: path}), do: length(path)

  @doc "Returns the ID of the last round in the active path, or `nil` if empty."
  @spec head(t()) :: round_id() | nil
  def head(%__MODULE__{active_path: []}), do: nil
  def head(%__MODULE__{active_path: path}), do: List.last(path)

  @doc "Returns the round data for a given ID, or `nil` if not found."
  @spec get_round(t(), round_id()) :: round() | nil
  def get_round(%__MODULE__{rounds: rounds}, id), do: Map.get(rounds, id)

  # Mutate

  @doc """
  Creates a new round and appends it to the active path.

  The new round's parent is the current `head/1` (or `nil` if the tree is
  empty). Returns `{round_id, updated_tree}`.
  """
  @spec push(t(), [Message.t()], Usage.t()) :: {round_id(), t()}
  def push(%__MODULE__{rounds: rounds, active_path: path} = tree, messages, %Usage{} = usage) do
    id = map_size(rounds)

    rounds = Map.put(rounds, id, %{
      parent: head(tree),
      messages: messages,
      usage: usage
    })

    {id, %{tree | rounds: rounds, active_path: path ++ [id]}}
  end

  @doc """
  Sets the active path by walking parent pointers from `round_id` back to root.

  Returns `{:error, :not_found}` if the round ID doesn't exist in the tree.
  """
  @spec navigate(t(), round_id()) :: {:ok, t()} | {:error, :not_found}
  def navigate(%__MODULE__{rounds: rounds} = tree, round_id) do
    case walk_to_root(rounds, round_id) do
      {:ok, path} -> {:ok, %{tree | active_path: path}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resets the active path to `[]` but preserves all rounds.

  A subsequent `push/3` starts a new root round (`parent: nil`).
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = tree), do: %{tree | active_path: []}

  # Introspect

  @doc "Returns the IDs of all rounds whose parent is the given round."
  @spec children(t(), round_id()) :: [round_id()]
  def children(%__MODULE__{rounds: rounds}, round_id) do
    rounds
    |> Enum.filter(fn {_id, round} -> round.parent == round_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Returns other children of the same parent, excluding the given round."
  @spec siblings(t(), round_id()) :: [round_id()]
  def siblings(%__MODULE__{rounds: rounds} = tree, round_id) do
    case Map.get(rounds, round_id) do
      nil ->
        []

      %{parent: nil} ->
        roots(tree) -- [round_id]

      %{parent: parent_id} ->
        children(tree, parent_id) -- [round_id]
    end
  end

  @doc """
  Walks parent pointers from `round_id` to root, returns the path in root-first order.

  Useful for UIs that need to show the full path to a specific branch point.
  """
  @spec path_to(t(), round_id()) :: {:ok, [round_id()]} | {:error, :not_found}
  def path_to(%__MODULE__{rounds: rounds}, round_id), do: walk_to_root(rounds, round_id)

  @doc "Returns IDs of all rounds with `parent: nil`."
  @spec roots(t()) :: [round_id()]
  def roots(%__MODULE__{rounds: rounds}) do
    rounds
    |> Enum.filter(fn {_id, round} -> round.parent == nil end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Internal

  defp walk_to_root(rounds, id, acc \\ [])

  defp walk_to_root(rounds, id, acc) do
    case Map.get(rounds, id) do
      nil -> {:error, :not_found}
      %{parent: nil} -> {:ok, [id | acc]}
      %{parent: parent_id} -> walk_to_root(rounds, parent_id, [id | acc])
    end
  end

  defimpl Enumerable do
    def reduce(tree, cmd, fun) do
      tree.active_path
      |> Enum.map(& {&1, tree.rounds[&1]})
      |> Enumerable.List.reduce(cmd, fun)
    end

    def count(tree), do: {:ok, length(tree.active_path)}
    def member?(_tree, _element), do: {:error, __MODULE__}
    def slice(_tree), do: {:error, __MODULE__}
  end
end
