defmodule Omni.SourceTest do
  use ExUnit.Case, async: true

  alias Omni.Source

  describe "with_cache/1 and memo/2" do
    test "memo runs the function on every call outside a cache scope" do
      first = Source.memo(:key, fn -> :erlang.unique_integer() end)
      second = Source.memo(:key, fn -> :erlang.unique_integer() end)

      refute first == second
    end

    test "memo caches per key within a cache scope" do
      {a, b, c} =
        Source.with_cache(fn ->
          a = Source.memo(:key, fn -> :erlang.unique_integer() end)
          b = Source.memo(:key, fn -> :erlang.unique_integer() end)
          c = Source.memo(:other_key, fn -> :erlang.unique_integer() end)
          {a, b, c}
        end)

      assert a == b
      refute a == c
    end

    test "with_cache returns the function's result" do
      assert Source.with_cache(fn -> :result end) == :result
    end

    test "each cache scope is independent" do
      first = Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)
      second = Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)

      refute first == second
    end

    test "the scope is cleared when the function raises" do
      assert_raise RuntimeError, "boom", fn ->
        Source.with_cache(fn ->
          Source.memo(:key, fn -> :cached end)
          raise "boom"
        end)
      end

      # Outside any scope now — memo must recompute, not see :cached.
      assert Source.memo(:key, fn -> :recomputed end) == :recomputed
    end

    test "a nested with_cache reuses the enclosing scope" do
      Source.with_cache(fn ->
        outer = Source.memo(:key, fn -> :erlang.unique_integer() end)

        inner =
          Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)

        assert inner == outer

        # The inner call's exit must not have torn the scope down.
        assert Source.memo(:key, fn -> :erlang.unique_integer() end) == outer
      end)
    end
  end
end
