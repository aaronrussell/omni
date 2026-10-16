defmodule Omni.Dialect.ThinkingTest do
  use ExUnit.Case, async: true

  alias Omni.Dialect.Thinking
  alias Omni.Model

  doctest Thinking

  defp model(thinking), do: Model.new(id: "m", name: "M", thinking: thinking)

  describe "resolve/2" do
    test "sends nothing when unset or the model doesn't reason" do
      assert Thinking.resolve(model(true), nil) == nil
      assert Thinking.resolve(model(false), :high) == nil
      assert Thinking.resolve(model(false), false) == nil
      assert Thinking.resolve(model(false), true) == nil
    end

    test "true is dynamic" do
      assert Thinking.resolve(model(true), true) == :dynamic
      assert Thinking.resolve(model(%{toggle: true}), true) == :dynamic
    end

    test "false is :off when the model can switch off" do
      assert Thinking.resolve(model(true), false) == :off
      assert Thinking.resolve(model(%{toggle: true}), false) == :off
      assert Thinking.resolve(model(%{efforts: ["none", "low"]}), false) == :off
    end

    test "false sends nothing when the data shows no off switch" do
      assert Thinking.resolve(model(%{efforts: ["low", "high"]}), false) == nil
      assert Thinking.resolve(model(%{budget: {128, 32_768}}), false) == nil
    end

    test "levels clamp up to the nearest supported value, else down" do
      oss = model(%{efforts: ["low", "medium", "high"]})
      assert %{effort: "low"} = Thinking.resolve(oss, :low)
      assert %{effort: "high"} = Thinking.resolve(oss, :xhigh)
      assert %{effort: "high"} = Thinking.resolve(oss, :max)

      gemini_image = model(%{efforts: ["minimal", "high"]})
      assert %{effort: "high"} = Thinking.resolve(gemini_image, :low)

      pro = model(%{efforts: ["high"]})
      assert %{effort: "high"} = Thinking.resolve(pro, :low)

      kimi = model(%{efforts: ["low", "high", "max"]})
      assert %{effort: "high"} = Thinking.resolve(kimi, :medium)
      assert %{effort: "max"} = Thinking.resolve(kimi, :xhigh)
    end

    test "never crosses into off" do
      assert %{effort: "low"} = Thinking.resolve(model(%{efforts: ["none", "low"]}), :low)
      assert %{effort: "low"} = Thinking.resolve(model(%{efforts: ["none", "low"]}), :max)
      assert %{effort: nil} = Thinking.resolve(model(%{efforts: ["none"]}), :high)
    end

    test "default stands in when it is the only on value" do
      qwen = model(%{efforts: ["none", "default"]})
      assert %{effort: "default"} = Thinking.resolve(qwen, :low)
      assert %{effort: "default"} = Thinking.resolve(qwen, :max)

      mixed = model(%{efforts: ["none", "default", "low", "medium", "high"]})
      assert %{effort: "high"} = Thinking.resolve(mixed, :max)
    end

    test "toggle-only models have no effort or budget" do
      assert Thinking.resolve(model(%{toggle: true}), :high) ==
               %{level: :high, effort: nil, budget: nil}
    end

    test "budget models get level budgets clamped to their range" do
      flash = model(%{toggle: true, budget: {0, 24_576}})
      assert %{effort: nil, budget: 1024} = Thinking.resolve(flash, :low)
      assert %{budget: 24_576} = Thinking.resolve(flash, :max)

      haiku = model(%{budget: {2048, nil}})
      assert %{budget: 2048} = Thinking.resolve(haiku, :low)
      assert %{budget: 32_768} = Thinking.resolve(haiku, :max)
    end

    test "an explicit budget is used, clamped, on budget models only" do
      flash = model(%{budget: {0, 24_576}})
      assert %{budget: 8000} = Thinking.resolve(flash, %{budget: 8000})
      assert %{budget: 24_576} = Thinking.resolve(flash, %{budget: 50_000})

      oss = model(%{efforts: ["low", "medium", "high"]})

      assert %{effort: "medium", budget: nil} =
               Thinking.resolve(oss, %{effort: :medium, budget: 8000})
    end

    test "the map form defaults its effort to :high" do
      assert %{level: :high} = Thinking.resolve(model(true), %{budget: 8000})
    end

    test "toggle and effort together" do
      deepseek = model(%{toggle: true, efforts: ["high", "max"]})
      assert Thinking.resolve(deepseek, false) == :off
      assert %{effort: "high"} = Thinking.resolve(deepseek, :low)
    end

    test "no data: no effort, a level budget" do
      assert Thinking.resolve(model(true), :high) == %{level: :high, effort: nil, budget: 16_384}
    end
  end

  describe "budget/2" do
    test "returns the level budget clamped to the model's range" do
      assert Thinking.budget(model(true), :medium) == 4096
      assert Thinking.budget(model(%{budget: {0, 24_576}}), :max) == 24_576
    end
  end
end
