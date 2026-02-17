defmodule Omni.UsageTest do
  use ExUnit.Case, async: true

  alias Omni.Usage

  describe "new/1" do
    test "creates usage from keyword list" do
      usage = Usage.new(input_tokens: 100, output_tokens: 50, total_tokens: 150)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.total_tokens == 150
    end

    test "defaults all fields to zero" do
      usage = Usage.new([])

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.cache_read_tokens == 0
      assert usage.cache_write_tokens == 0
      assert usage.total_tokens == 0
      assert usage.input_cost == 0
      assert usage.output_cost == 0
      assert usage.cache_read_cost == 0
      assert usage.cache_write_cost == 0
      assert usage.total_cost == 0
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Usage.new(bogus: true)
      end
    end
  end

  describe "add/2" do
    test "sums corresponding fields of two usage structs" do
      a = Usage.new(input_tokens: 100, output_tokens: 50, input_cost: 3, total_cost: 5)
      b = Usage.new(input_tokens: 200, output_tokens: 75, input_cost: 6, total_cost: 10)

      result = Usage.add(a, b)

      assert result.input_tokens == 300
      assert result.output_tokens == 125
      assert result.input_cost == 9
      assert result.total_cost == 15
    end

    test "works when one struct has defaults" do
      a = Usage.new(input_tokens: 100, output_tokens: 50)
      b = Usage.new([])

      result = Usage.add(a, b)

      assert result.input_tokens == 100
      assert result.output_tokens == 50
      assert result.cache_read_tokens == 0
    end
  end

  describe "sum/1" do
    test "reduces a list of usages" do
      usages = [
        Usage.new(input_tokens: 100, input_cost: 3),
        Usage.new(input_tokens: 200, input_cost: 6),
        Usage.new(input_tokens: 50, input_cost: 1)
      ]

      result = Usage.sum(usages)

      assert result.input_tokens == 350
      assert result.input_cost == 10
    end

    test "returns zero usage for empty list" do
      result = Usage.sum([])

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_cost == 0
    end
  end
end
