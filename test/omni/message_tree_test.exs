defmodule Omni.MessageTreeTest do
  use ExUnit.Case, async: true

  alias Omni.{Message, MessageTree, Usage}

  defp msg(text), do: Message.new(text)
  defp assistant(text), do: Message.new(role: :assistant, content: text)
  defp usage(input, output), do: Usage.new(input_tokens: input, output_tokens: output)

  # Builds the example tree from the spec:
  #
  #   0 ── 1 ── 2 ── 3
  #             │
  #             ├── 4 ── 5
  #             │
  #             └── 6
  #
  # Active path: [0, 1, 4, 5]
  defp example_tree do
    tree = %MessageTree{}

    {0, tree} = MessageTree.push(tree, [msg("r0")], usage(10, 5))
    {1, tree} = MessageTree.push(tree, [msg("r1"), assistant("a1")], usage(20, 10))

    # Push round 2 (child of 1) — will become inactive branch
    {2, tree} = MessageTree.push(tree, [msg("r2")], usage(30, 15))

    # Push round 3 (child of 2)
    {3, tree} = MessageTree.push(tree, [msg("r3")], usage(40, 20))

    # Navigate back to round 1 and push round 4 (branch from 1)
    {:ok, tree} = MessageTree.navigate(tree, 1)
    {4, tree} = MessageTree.push(tree, [msg("r4")], usage(50, 25))

    # Push round 5 (child of 4)
    {5, tree} = MessageTree.push(tree, [msg("r5")], usage(60, 30))

    # Navigate back to round 1 and push round 6 (another branch from 1)
    {:ok, tree} = MessageTree.navigate(tree, 1)
    {6, tree} = MessageTree.push(tree, [msg("r6")], usage(70, 35))

    # Navigate to round 5 to set active path to [0, 1, 4, 5]
    {:ok, tree} = MessageTree.navigate(tree, 5)

    tree
  end

  describe "push/3" do
    test "push to empty tree creates round 0 with parent nil" do
      {id, tree} = MessageTree.push(%MessageTree{}, [msg("hello")], usage(10, 5))

      assert id == 0
      assert tree.active_path == [0]
      assert tree.rounds[0].parent == nil
      assert [%Message{role: :user}] = tree.rounds[0].messages
      assert tree.rounds[0].usage.input_tokens == 10
    end

    test "push to non-empty tree sets parent to previous head" do
      {_, tree} = MessageTree.push(%MessageTree{}, [msg("first")], usage(10, 5))
      {id, tree} = MessageTree.push(tree, [msg("second")], usage(20, 10))

      assert id == 1
      assert tree.rounds[1].parent == 0
      assert tree.active_path == [0, 1]
    end

    test "sequential pushes build a linear chain" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))
      {2, tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))

      assert tree.active_path == [0, 1, 2]
      assert tree.rounds[0].parent == nil
      assert tree.rounds[1].parent == 0
      assert tree.rounds[2].parent == 1
    end

    test "assigns sequential IDs based on map size" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      # Navigate back and branch — next ID is still 2 (map_size)
      {:ok, tree} = MessageTree.navigate(tree, 0)
      {2, _tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))
    end
  end

  describe "navigate/2" do
    test "navigate to existing round sets active path" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))
      {2, tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))

      {:ok, tree} = MessageTree.navigate(tree, 1)

      assert tree.active_path == [0, 1]
      assert MessageTree.head(tree) == 1
    end

    test "navigate to root round" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      {:ok, tree} = MessageTree.navigate(tree, 0)

      assert tree.active_path == [0]
    end

    test "navigate to non-existent round returns error" do
      assert {:error, :not_found} = MessageTree.navigate(%MessageTree{}, 99)
    end

    test "navigate then push creates a branch" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      {:ok, tree} = MessageTree.navigate(tree, 0)
      {2, tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))

      # Round 2 branches from round 0
      assert tree.rounds[2].parent == 0
      assert tree.active_path == [0, 2]

      # Both round 1 and round 2 are children of round 0
      assert MapSet.new(MessageTree.children(tree, 0)) == MapSet.new([1, 2])
    end
  end

  describe "clear/1" do
    test "clears active path but preserves rounds" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      tree = MessageTree.clear(tree)

      assert tree.active_path == []
      assert map_size(tree.rounds) == 2
    end

    test "push after clear creates a new root" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      assert tree.rounds[1].parent == nil
      assert tree.active_path == [1]
    end

    test "clearing an already empty path is idempotent" do
      tree = MessageTree.clear(%MessageTree{})

      assert tree.active_path == []
      assert tree.rounds == %{}
    end
  end

  describe "messages/1" do
    test "returns flat list of messages along active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a"), assistant("r1")], usage(1, 1))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      messages = MessageTree.messages(tree)

      assert length(messages) == 3
      assert [%{role: :user}, %{role: :assistant}, %{role: :user}] = messages
    end

    test "returns empty list for empty tree" do
      assert MessageTree.messages(%MessageTree{}) == []
    end

    test "returns empty list after clear" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))

      tree = MessageTree.clear(tree)

      assert MessageTree.messages(tree) == []
    end

    test "reflects active branch only" do
      tree = example_tree()
      messages = MessageTree.messages(tree)

      texts =
        Enum.flat_map(messages, fn m ->
          Enum.map(m.content, fn c -> c.text end)
        end)

      # Active path is [0, 1, 4, 5] — should see r0, r1, a1, r4, r5
      assert texts == ["r0", "r1", "a1", "r4", "r5"]
    end
  end

  describe "usage/1" do
    test "sums usage across active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(10, 5))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(20, 10))

      result = MessageTree.usage(tree)

      assert result.input_tokens == 30
      assert result.output_tokens == 15
    end

    test "returns zero usage for empty tree" do
      result = MessageTree.usage(%MessageTree{})

      assert result.input_tokens == 0
      assert result.output_tokens == 0
    end
  end

  describe "round_count/1" do
    test "returns length of active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      assert MessageTree.round_count(tree) == 2
    end

    test "returns 0 for empty tree" do
      assert MessageTree.round_count(%MessageTree{}) == 0
    end
  end

  describe "head/1" do
    test "returns last round ID in active path" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))
      {_, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      assert MessageTree.head(tree) == 1
    end

    test "returns nil for empty tree" do
      assert MessageTree.head(%MessageTree{}) == nil
    end
  end

  describe "get_round/2" do
    test "returns round data for existing ID" do
      {_, tree} = MessageTree.push(%MessageTree{}, [msg("hello")], usage(10, 5))

      round = MessageTree.get_round(tree, 0)

      assert round.parent == nil
      assert round.usage.input_tokens == 10
      assert [%Message{}] = round.messages
    end

    test "returns nil for non-existent ID" do
      assert MessageTree.get_round(%MessageTree{}, 99) == nil
    end
  end

  describe "children/2" do
    test "returns child round IDs" do
      tree = example_tree()

      # Round 1 has children 2, 4, 6
      children = MessageTree.children(tree, 1)
      assert children == [2, 4, 6]
    end

    test "returns empty list for leaf node" do
      tree = example_tree()

      assert MessageTree.children(tree, 3) == []
      assert MessageTree.children(tree, 5) == []
      assert MessageTree.children(tree, 6) == []
    end

    test "returns single child for non-branch node" do
      tree = example_tree()

      assert MessageTree.children(tree, 0) == [1]
      assert MessageTree.children(tree, 4) == [5]
    end
  end

  describe "siblings/2" do
    test "returns sibling round IDs excluding self" do
      tree = example_tree()

      # Rounds 2, 4, 6 are all children of round 1
      assert MessageTree.siblings(tree, 2) == [4, 6]
      assert MessageTree.siblings(tree, 4) == [2, 6]
      assert MessageTree.siblings(tree, 6) == [2, 4]
    end

    test "returns empty list when no siblings" do
      tree = example_tree()

      assert MessageTree.siblings(tree, 0) == []
      assert MessageTree.siblings(tree, 1) == []
      assert MessageTree.siblings(tree, 5) == []
    end

    test "handles root-level siblings" do
      tree = %MessageTree{}
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      tree = MessageTree.clear(tree)
      {2, tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))

      assert MessageTree.siblings(tree, 0) == [1, 2]
      assert MessageTree.siblings(tree, 1) == [0, 2]
      assert MessageTree.siblings(tree, 2) == [0, 1]
    end

    test "returns empty list for non-existent round" do
      assert MessageTree.siblings(%MessageTree{}, 99) == []
    end
  end

  describe "path_to/2" do
    test "returns root-first path for existing round" do
      tree = example_tree()

      assert {:ok, [0, 1, 4, 5]} = MessageTree.path_to(tree, 5)
      assert {:ok, [0, 1, 2, 3]} = MessageTree.path_to(tree, 3)
      assert {:ok, [0, 1, 6]} = MessageTree.path_to(tree, 6)
    end

    test "returns error for non-existent round" do
      assert {:error, :not_found} = MessageTree.path_to(%MessageTree{}, 99)
    end

    test "path to root round is just the root" do
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
      {0, tree} = MessageTree.push(tree, [msg("a")], usage(1, 1))

      tree = MessageTree.clear(tree)
      {1, tree} = MessageTree.push(tree, [msg("b")], usage(2, 2))

      tree = MessageTree.clear(tree)
      {2, tree} = MessageTree.push(tree, [msg("c")], usage(3, 3))

      assert MessageTree.roots(tree) == [0, 1, 2]
    end

    test "returns empty list for empty tree" do
      assert MessageTree.roots(%MessageTree{}) == []
    end
  end

  describe "Enumerable" do
    test "Enum.map yields {id, round} tuples for active path" do
      tree = example_tree()

      result = Enum.map(tree, fn {id, _round} -> id end)

      assert result == [0, 1, 4, 5]
    end

    test "Enum.count returns active path length" do
      tree = example_tree()

      assert Enum.count(tree) == 4
    end

    test "Enum.to_list on empty tree returns empty list" do
      assert Enum.to_list(%MessageTree{}) == []
    end

    test "iteration yields full round data" do
      tree = %MessageTree{}
      {_, tree} = MessageTree.push(tree, [msg("hello")], usage(10, 5))

      [{id, round}] = Enum.to_list(tree)

      assert id == 0
      assert round.parent == nil
      assert round.usage.input_tokens == 10
    end

    test "iterates only the active path" do
      tree = example_tree()

      # Active path is [0, 1, 4, 5] — should not see rounds 2, 3, 6
      ids = Enum.map(tree, fn {id, _} -> id end)
      assert ids == [0, 1, 4, 5]
      refute 2 in ids
      refute 3 in ids
      refute 6 in ids
    end
  end

  describe "integration: spec example tree" do
    test "full tree structure matches spec" do
      tree = example_tree()

      # 7 rounds total
      assert map_size(tree.rounds) == 7

      # Active path is [0, 1, 4, 5]
      assert tree.active_path == [0, 1, 4, 5]

      # Parent pointers
      assert tree.rounds[0].parent == nil
      assert tree.rounds[1].parent == 0
      assert tree.rounds[2].parent == 1
      assert tree.rounds[3].parent == 2
      assert tree.rounds[4].parent == 1
      assert tree.rounds[5].parent == 4
      assert tree.rounds[6].parent == 1
    end

    test "navigate to round 3 shows that branch" do
      tree = example_tree()

      {:ok, tree} = MessageTree.navigate(tree, 3)

      assert tree.active_path == [0, 1, 2, 3]
      assert MessageTree.head(tree) == 3

      texts =
        tree
        |> MessageTree.messages()
        |> Enum.flat_map(fn m -> Enum.map(m.content, & &1.text) end)

      assert texts == ["r0", "r1", "a1", "r2", "r3"]
    end

    test "navigate back to round 5 restores original path" do
      tree = example_tree()

      {:ok, tree} = MessageTree.navigate(tree, 3)
      {:ok, tree} = MessageTree.navigate(tree, 5)

      assert tree.active_path == [0, 1, 4, 5]
    end

    test "usage reflects active branch" do
      tree = example_tree()

      # Active path [0, 1, 4, 5]: input = 10 + 20 + 50 + 60 = 140
      assert MessageTree.usage(tree).input_tokens == 140

      {:ok, tree} = MessageTree.navigate(tree, 3)

      # Path [0, 1, 2, 3]: input = 10 + 20 + 30 + 40 = 100
      assert MessageTree.usage(tree).input_tokens == 100
    end
  end
end
