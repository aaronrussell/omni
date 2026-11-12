defmodule Omni.Dialect.TextTest do
  use ExUnit.Case, async: true

  alias Omni.Dialect.Text
  alias Omni.Model

  doctest Text

  defp model(thinking), do: Model.new(id: "m", name: "M", thinking: thinking)

  describe "resolve_thinking/2" do
    test "sends nothing when unset or the model doesn't reason" do
      assert Text.resolve_thinking(model(true), nil) == nil
      assert Text.resolve_thinking(model(false), :high) == nil
      assert Text.resolve_thinking(model(false), false) == nil
      assert Text.resolve_thinking(model(false), true) == nil
    end

    test "true is :medium" do
      assert Text.resolve_thinking(model(true), true) == %{
               level: :medium,
               effort: nil,
               budget: 4096
             }

      assert Text.resolve_thinking(model(%{toggle: true}), true) ==
               %{level: :medium, effort: nil, budget: nil}

      assert %{effort: "high"} = Text.resolve_thinking(model(%{efforts: ["low", "high"]}), true)
    end

    test "false is :off when the model can switch off" do
      assert Text.resolve_thinking(model(true), false) == :off
      assert Text.resolve_thinking(model(%{toggle: true}), false) == :off
      assert Text.resolve_thinking(model(%{efforts: ["none", "low"]}), false) == :off
    end

    test "false sends nothing when the data shows no off switch" do
      assert Text.resolve_thinking(model(%{efforts: ["low", "high"]}), false) == nil
      assert Text.resolve_thinking(model(%{budget: {128, 32_768}}), false) == nil
    end

    test "levels clamp up to the nearest supported value, else down" do
      oss = model(%{efforts: ["low", "medium", "high"]})
      assert %{effort: "low"} = Text.resolve_thinking(oss, :low)
      assert %{effort: "high"} = Text.resolve_thinking(oss, :xhigh)
      assert %{effort: "high"} = Text.resolve_thinking(oss, :max)

      gemini_image = model(%{efforts: ["minimal", "high"]})
      assert %{effort: "high"} = Text.resolve_thinking(gemini_image, :low)

      pro = model(%{efforts: ["high"]})
      assert %{effort: "high"} = Text.resolve_thinking(pro, :low)

      kimi = model(%{efforts: ["low", "high", "max"]})
      assert %{effort: "high"} = Text.resolve_thinking(kimi, :medium)
      assert %{effort: "max"} = Text.resolve_thinking(kimi, :xhigh)
    end

    test "never crosses into off" do
      assert %{effort: "low"} = Text.resolve_thinking(model(%{efforts: ["none", "low"]}), :low)
      assert %{effort: "low"} = Text.resolve_thinking(model(%{efforts: ["none", "low"]}), :max)
      assert %{effort: nil} = Text.resolve_thinking(model(%{efforts: ["none"]}), :high)
    end

    test "default stands in when it is the only on value" do
      qwen = model(%{efforts: ["none", "default"]})
      assert %{effort: "default"} = Text.resolve_thinking(qwen, :low)
      assert %{effort: "default"} = Text.resolve_thinking(qwen, :max)

      mixed = model(%{efforts: ["none", "default", "low", "medium", "high"]})
      assert %{effort: "high"} = Text.resolve_thinking(mixed, :max)
    end

    test "toggle-only models have no effort or budget" do
      assert Text.resolve_thinking(model(%{toggle: true}), :high) ==
               %{level: :high, effort: nil, budget: nil}
    end

    test "budget models get level budgets clamped to their range" do
      flash = model(%{toggle: true, budget: {0, 24_576}})
      assert %{effort: nil, budget: 1024} = Text.resolve_thinking(flash, :low)
      assert %{budget: 24_576} = Text.resolve_thinking(flash, :max)

      haiku = model(%{budget: {2048, nil}})
      assert %{budget: 2048} = Text.resolve_thinking(haiku, :low)
      assert %{budget: 32_768} = Text.resolve_thinking(haiku, :max)
    end

    test "an explicit budget is used, clamped, on budget models only" do
      flash = model(%{budget: {0, 24_576}})
      assert %{budget: 8000} = Text.resolve_thinking(flash, %{budget: 8000})
      assert %{budget: 24_576} = Text.resolve_thinking(flash, %{budget: 50_000})

      oss = model(%{efforts: ["low", "medium", "high"]})

      assert %{effort: "medium", budget: nil} =
               Text.resolve_thinking(oss, %{effort: :medium, budget: 8000})
    end

    test "the map form defaults its effort to :high" do
      assert %{level: :high} = Text.resolve_thinking(model(true), %{budget: 8000})
    end

    test "toggle and effort together" do
      deepseek = model(%{toggle: true, efforts: ["high", "max"]})
      assert Text.resolve_thinking(deepseek, false) == :off
      assert %{effort: "high"} = Text.resolve_thinking(deepseek, :low)
    end

    test "no data: no effort, a level budget" do
      assert Text.resolve_thinking(model(true), :high) == %{
               level: :high,
               effort: nil,
               budget: 16_384
             }
    end
  end

  describe "thinking_budget/2" do
    test "returns the level budget clamped to the model's range" do
      assert Text.thinking_budget(model(true), :medium) == 4096
      assert Text.thinking_budget(model(%{budget: {0, 24_576}}), :max) == 24_576
    end
  end
end
