defmodule Omni.MessageTree do
  @moduledoc """
  A tree of conversation messages with a cursor pointing to the active path.

  Each message has a unique integer ID and a parent pointer. Multiple messages
  can share the same parent — this is how branching (regeneration, forking)
  works.

  The tree supports three core operations: pushing new messages, navigating to
  any message in the tree, and querying the active path.

  ## Enumerable

  Iterating over a `MessageTree` yields `tree_node()` maps for each node
  in the **active path**, in order. Each node has `:id`, `:parent_id`, and
  `:message` keys. Use `tree.nodes` to access the full tree including
  inactive branches.
  """

  alias Omni.Message

  @typedoc "Integer node identifier, assigned sequentially by `push/2`."
  @type id :: non_neg_integer()

  @typedoc "A node in the tree: a message with its position."
  @type tree_node :: %{id: id(), parent_id: id() | nil, message: Message.t()}

  @typedoc "A tree of conversation messages with an active path cursor."
  @type t :: %__MODULE__{
          nodes: %{id() => tree_node()},
          path: [id()]
        }

  defstruct nodes: %{}, path: []

  # Query

  @doc "Returns a flat list of all messages along the active path, in order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{nodes: nodes, path: path}) do
    Enum.map(path, fn id -> nodes[id].message end)
  end

  @doc "Returns the number of messages in the active path."
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{path: path}), do: length(path)

  @doc "Returns the ID of the last message in the active path, or `nil` if empty."
  @spec head(t()) :: id() | nil
  def head(%__MODULE__{path: []}), do: nil
  def head(%__MODULE__{path: path}), do: List.last(path)

  @doc "Returns the message for a given ID, or `nil` if not found."
  @spec get_message(t(), id()) :: Message.t() | nil
  def get_message(%__MODULE__{nodes: nodes}, id) do
    case Map.get(nodes, id) do
      %{message: message} -> message
      nil -> nil
    end
  end

  # Mutate

  @doc """
  Pushes a message onto the tree and appends it to the active path.

  The new node's parent is the current `head/1` (or `nil` if the tree is
  empty). Returns `{id, updated_tree}`.
  """
  @spec push(t(), Message.t()) :: {id(), t()}
  def push(%__MODULE__{nodes: nodes, path: path} = tree, %Message{} = message) do
    id = map_size(nodes)
    node = %{id: id, parent_id: head(tree), message: message}
    nodes = Map.put(nodes, id, node)

    {id, %{tree | nodes: nodes, path: path ++ [id]}}
  end

  @doc """
  Sets the active path by walking parent pointers from `node_id` back to root.

  Returns `{:error, :not_found}` if the node ID doesn't exist in the tree.
  """
  @spec navigate(t(), id()) :: {:ok, t()} | {:error, :not_found}
  def navigate(%__MODULE__{nodes: nodes} = tree, node_id) do
    case walk_to_root(nodes, node_id) do
      {:ok, path} -> {:ok, %{tree | path: path}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resets the active path to `[]` but preserves all nodes.

  A subsequent `push/2` starts a new root node (`parent_id: nil`).
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = tree), do: %{tree | path: []}

  # Introspect

  @doc "Returns the IDs of all nodes whose parent is the given node."
  @spec children(t(), id()) :: [id()]
  def children(%__MODULE__{nodes: nodes}, node_id) do
    nodes
    |> Enum.filter(fn {_id, node} -> node.parent_id == node_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Returns other children of the same parent, excluding the given node."
  @spec siblings(t(), id()) :: [id()]
  def siblings(%__MODULE__{nodes: nodes} = tree, node_id) do
    case Map.get(nodes, node_id) do
      nil ->
        []

      %{parent_id: nil} ->
        roots(tree) -- [node_id]

      %{parent_id: parent_id} ->
        children(tree, parent_id) -- [node_id]
    end
  end

  @doc """
  Walks parent pointers from `node_id` to root, returns the path in root-first order.

  Useful for UIs that need to show the full path to a specific branch point.
  """
  @spec path_to(t(), id()) :: {:ok, [id()]} | {:error, :not_found}
  def path_to(%__MODULE__{nodes: nodes}, node_id), do: walk_to_root(nodes, node_id)

  @doc "Returns IDs of all nodes with `parent_id: nil`."
  @spec roots(t()) :: [id()]
  def roots(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(fn {_id, node} -> node.parent_id == nil end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Internal

  defp walk_to_root(nodes, id, acc \\ [])

  defp walk_to_root(nodes, id, acc) do
    case Map.get(nodes, id) do
      nil -> {:error, :not_found}
      %{parent_id: nil} -> {:ok, [id | acc]}
      %{parent_id: parent_id} -> walk_to_root(nodes, parent_id, [id | acc])
    end
  end

  defimpl Enumerable do
    def reduce(tree, cmd, fun) do
      tree.path
      |> Enum.map(&tree.nodes[&1])
      |> Enumerable.List.reduce(cmd, fun)
    end

    def count(tree), do: {:ok, length(tree.path)}
    def member?(_tree, _element), do: {:error, __MODULE__}
    def slice(_tree), do: {:error, __MODULE__}
  end
end
