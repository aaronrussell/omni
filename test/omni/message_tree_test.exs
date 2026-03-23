defmodule Omni.MessageTreeTest do
  use ExUnit.Case, async: true

  alias Omni.{Message, MessageTree}

  defp msg(text), do: Message.new(text)
  defp assistant(text), do: Message.new(role: :assistant, content: text)

  # Builds the example tree from the spec:
  #
  #   0 ── 1 ── 2 ── 3 ── 4 ── 5
  #                   │
  #                   ├── 6 ── 7
  #                   │
  #                   └── 8
  #
  # Messages: 0=r0, 1=a0, 2=r1, 3=a1, 4=r2, 5=a2 (linear)
  # Branch at node 3: 6=r3alt, 7=a3alt
  # Branch at node 3: 8=r3alt2
  # Active path: [0, 1, 2, 3, 6, 7]
  defp example_tree do
    tree = %MessageTree{}

    # Linear conversation: user, assistant, user, assistant, user, assistant
    {0, tree} = MessageTree.push(tree, msg("r0"))
    {1, tree} = MessageTree.push(tree, assistant("a0"))
    {2, tree} = MessageTree.push(tree, msg("r1"))
    {3, tree} = MessageTree.push(tree, assistant("a1"))
    {4, tree} = MessageTree.push(tree, msg("r2"))
    {5, tree} = MessageTree.push(tree, assistant("a2"))

    # Navigate back to node 3 (assistant a1) and branch
    {:ok, tree} = MessageTree.navigate(tree, 3)
    {6, tree} = MessageTree.push(tree, msg("r3alt"))
    {7, tree} = MessageTree.push(tree, assistant("a3alt"))

    # Navigate back to node 3 again and branch again
    {:ok, tree} = MessageTree.navigate(tree, 3)
    {8, tree} = MessageTree.push(tree, msg("r3alt2"))

    # Navigate to node 7 to set active path
    {:ok, tree} = MessageTree.navigate(tree, 7)

    tree
  end

  describe "push/2" do
    test "push to empty tree creates node 0 with parent nil" do
      {id, tree} = MessageTree.push(%MessageTree{}, msg("hello"))

      assert id == 0
      assert tree.path == [0]
      assert tree.nodes[0].node.parent_id == nil
      assert %Message{role: :user} = tree.nodes[0]
    end

    test "push to non-empty tree sets parent to previous head" do
      {_, tree} = MessageTree.push(%MessageTree{}, msg("first"))
      {id, tree} = MessageTree.push(tree, msg("second"))

      assert id == 1
      assert tree.nodes[1].node.parent_id == 0
      assert tree.path == [0, 1]
    end

    test "sequential pushes build a linear chain" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))
      {1, tree} = MessageTree.push(tree, assistant("b"))
      {2, tree} = MessageTree.push(tree, msg("c"))

      assert tree.path == [0, 1, 2]
      assert tree.nodes[0].node.parent_id == nil
      assert tree.nodes[1].node.parent_id == 0
      assert tree.nodes[2].node.parent_id == 1
    end

    test "assigns sequential IDs based on map size" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))
      {1, tree} = MessageTree.push(tree, msg("b"))

      # Navigate back and branch — next ID is still 2 (map_size)
      {:ok, tree} = MessageTree.navigate(tree, 0)
      {2, _tree} = MessageTree.push(tree, msg("c"))
    end
  end

  describe "navigate/2" do
    test "navigate to existing node sets active path" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))
      {1, tree} = MessageTree.push(tree, msg("b"))
      {2, tree} = MessageTree.push(tree, msg("c"))

      {:ok, tree} = MessageTree.navigate(tree, 1)

      assert tree.path == [0, 1]
      assert MessageTree.head(tree) == 1
    end

    test "navigate to root node" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))
      {_, tree} = MessageTree.push(tree, msg("b"))

      {:ok, tree} = MessageTree.navigate(tree, 0)

      assert tree.path == [0]
    end

    test "navigate to non-existent node returns error" do
      assert {:error, :not_found} = MessageTree.navigate(%MessageTree{}, 99)
    end

    test "navigate then push creates a branch" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))
      {1, tree} = MessageTree.push(tree, msg("b"))

      {:ok, tree} = MessageTree.navigate(tree, 0)
      {2, tree} = MessageTree.push(tree, msg("c"))

      # Node 2 branches from node 0
      assert tree.nodes[2].node.parent_id == 0
      assert tree.path == [0, 2]

      # Both node 1 and node 2 are children of node 0
      assert MapSet.new(MessageTree.children(tree, 0)) == MapSet.new([1, 2])
    end
  end

  describe "clear/1" do
    test "clears active path but preserves nodes" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))
      {_, tree} = MessageTree.push(tree, msg("b"))

      tree = MessageTree.clear(tree)

      assert tree.path == []
      assert map_size(tree.nodes) == 2
    end

    test "push after clear creates a new root" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, msg("b"))

      assert tree.nodes[1].node.parent_id == nil
      assert tree.path == [1]
    end

    test "clearing an already empty path is idempotent" do
      tree = MessageTree.clear(%MessageTree{})

      assert tree.path == []
      assert tree.nodes == %{}
    end
  end

  describe "messages/1" do
    test "returns list of messages along active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))
      {_, tree} = MessageTree.push(tree, assistant("r1"))
      {_, tree} = MessageTree.push(tree, msg("b"))

      messages = MessageTree.messages(tree)

      assert length(messages) == 3
      assert [%{role: :user}, %{role: :assistant}, %{role: :user}] = messages
    end

    test "returns empty list for empty tree" do
      assert MessageTree.messages(%MessageTree{}) == []
    end

    test "returns empty list after clear" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))

      tree = MessageTree.clear(tree)

      assert MessageTree.messages(tree) == []
    end

    test "reflects active branch only" do
      tree = example_tree()
      messages = MessageTree.messages(tree)

      texts = Enum.map(messages, fn m -> hd(m.content).text end)

      # Active path is [0, 1, 2, 3, 6, 7] — should see r0, a0, r1, a1, r3alt, a3alt
      assert texts == ["r0", "a0", "r1", "a1", "r3alt", "a3alt"]
    end
  end

  describe "depth/1" do
    test "returns length of active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))
      {_, tree} = MessageTree.push(tree, msg("b"))

      assert MessageTree.depth(tree) == 2
    end

    test "returns 0 for empty tree" do
      assert MessageTree.depth(%MessageTree{}) == 0
    end
  end

  describe "head/1" do
    test "returns last node ID in active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("a"))
      {_, tree} = MessageTree.push(tree, msg("b"))

      assert MessageTree.head(tree) == 1
    end

    test "returns nil for empty tree" do
      assert MessageTree.head(%MessageTree{}) == nil
    end
  end

  describe "get_message/2" do
    test "returns message for existing ID" do
      {_, tree} = MessageTree.push(%MessageTree{}, msg("hello"))

      message = MessageTree.get_message(tree, 0)

      assert %Message{role: :user} = message
    end

    test "returns nil for non-existent ID" do
      assert MessageTree.get_message(%MessageTree{}, 99) == nil
    end
  end

  describe "children/2" do
    test "returns child node IDs" do
      tree = example_tree()

      # Node 3 (assistant a1) has children 4, 6, 8
      children = MessageTree.children(tree, 3)
      assert children == [4, 6, 8]
    end

    test "returns empty list for leaf node" do
      tree = example_tree()

      assert MessageTree.children(tree, 5) == []
      assert MessageTree.children(tree, 7) == []
      assert MessageTree.children(tree, 8) == []
    end

    test "returns single child for non-branch node" do
      tree = example_tree()

      assert MessageTree.children(tree, 0) == [1]
      assert MessageTree.children(tree, 6) == [7]
    end
  end

  describe "siblings/2" do
    test "returns sibling node IDs excluding self" do
      tree = example_tree()

      # Nodes 4, 6, 8 are all children of node 3
      assert MessageTree.siblings(tree, 4) == [6, 8]
      assert MessageTree.siblings(tree, 6) == [4, 8]
      assert MessageTree.siblings(tree, 8) == [4, 6]
    end

    test "returns empty list when no siblings" do
      tree = example_tree()

      assert MessageTree.siblings(tree, 0) == []
      assert MessageTree.siblings(tree, 1) == []
      assert MessageTree.siblings(tree, 7) == []
    end

    test "handles root-level siblings" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, msg("b"))

      tree = MessageTree.clear(tree)
      {2, tree} = MessageTree.push(tree, msg("c"))

      assert MessageTree.siblings(tree, 0) == [1, 2]
      assert MessageTree.siblings(tree, 1) == [0, 2]
      assert MessageTree.siblings(tree, 2) == [0, 1]
    end

    test "returns empty list for non-existent node" do
      assert MessageTree.siblings(%MessageTree{}, 99) == []
    end
  end

  describe "path_to/2" do
    test "returns root-first path for existing node" do
      tree = example_tree()

      assert {:ok, [0, 1, 2, 3, 6, 7]} = MessageTree.path_to(tree, 7)
      assert {:ok, [0, 1, 2, 3, 4, 5]} = MessageTree.path_to(tree, 5)
      assert {:ok, [0, 1, 2, 3, 8]} = MessageTree.path_to(tree, 8)
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = MessageTree.path_to(%MessageTree{}, 99)
    end

    test "path to root node is just the root" do
      tree = example_tree()

      assert {:ok, [0]} = MessageTree.path_to(tree, 0)
    end
  end

  describe "roots/1" do
    test "returns single root for normal tree" do
      tree = example_tree()

      assert MessageTree.roots(tree) == [0]
    end

    test "returns multiple roots after clear + push cycles" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, msg("a"))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, msg("b"))

      tree = MessageTree.clear(tree)
      {2, tree} = MessageTree.push(tree, msg("c"))

      assert MessageTree.roots(tree) == [0, 1, 2]
    end

    test "returns empty list for empty tree" do
      assert MessageTree.roots(%MessageTree{}) == []
    end
  end

  describe "Enumerable" do
    test "Enum.map yields messages for active path" do
      tree = example_tree()

      result = Enum.map(tree, fn %Message{node: %{id: id}} -> id end)

      assert result == [0, 1, 2, 3, 6, 7]
    end

    test "Enum.count returns active path length" do
      tree = example_tree()

      assert Enum.count(tree) == 6
    end

    test "Enum.to_list on empty tree returns empty list" do
      assert Enum.to_list(%MessageTree{}) == []
    end

    test "iteration yields messages with node data" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, msg("hello"))

      [message] = Enum.to_list(tree)

      assert %Message{role: :user} = message
      assert message.node.id == 0
      assert message.node.parent_id == nil
    end

    test "iterates only the active path" do
      tree = example_tree()

      # Active path is [0, 1, 2, 3, 6, 7] — should not see nodes 4, 5, 8
      ids = Enum.map(tree, fn %Message{node: %{id: id}} -> id end)
      assert ids == [0, 1, 2, 3, 6, 7]
      refute 4 in ids
      refute 5 in ids
      refute 8 in ids
    end
  end

  describe "integration: example tree" do
    test "full tree structure matches spec" do
      tree = example_tree()

      # 9 nodes total
      assert map_size(tree.nodes) == 9

      # Active path is [0, 1, 2, 3, 6, 7]
      assert tree.path == [0, 1, 2, 3, 6, 7]

      # Parent pointers
      assert tree.nodes[0].node.parent_id == nil
      assert tree.nodes[1].node.parent_id == 0
      assert tree.nodes[2].node.parent_id == 1
      assert tree.nodes[3].node.parent_id == 2
      assert tree.nodes[4].node.parent_id == 3
      assert tree.nodes[5].node.parent_id == 4
      assert tree.nodes[6].node.parent_id == 3
      assert tree.nodes[7].node.parent_id == 6
      assert tree.nodes[8].node.parent_id == 3
    end

    test "navigate to node 5 shows that branch" do
      tree = example_tree()

      {:ok, tree} = MessageTree.navigate(tree, 5)

      assert tree.path == [0, 1, 2, 3, 4, 5]
      assert MessageTree.head(tree) == 5

      texts =
        tree
        |> MessageTree.messages()
        |> Enum.map(fn m -> hd(m.content).text end)

      assert texts == ["r0", "a0", "r1", "a1", "r2", "a2"]
    end

    test "navigate back to node 7 restores original path" do
      tree = example_tree()

      {:ok, tree} = MessageTree.navigate(tree, 5)
      {:ok, tree} = MessageTree.navigate(tree, 7)

      assert tree.path == [0, 1, 2, 3, 6, 7]
    end
  end
end
