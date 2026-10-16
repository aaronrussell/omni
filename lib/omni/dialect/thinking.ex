defmodule Omni.Dialect.Thinking do
  @moduledoc """
  Resolves the `:thinking` request option against what a model accepts.

  Dialects call `resolve/2` with the model and the validated option, then
  spell the result in their wire format. The model's `:thinking` data (see
  `Omni.Model`) decides what is sent, so every dialect agrees on how levels
  map to a model's effort values and budgets:

    * Effort levels are clamped to the model's values on one ladder,
      `minimal < low < medium < high < xhigh < max`: round up to the nearest
      supported value, else down. A model whose only "on" value is
      `"default"` gets `"default"`.
    * Budgets come from the level (`low` 1024, `medium` 4096, `high` 16384,
      `xhigh` 24576, `max` 32768) unless one is given, clamped to the
      model's range.

  ## Results

    * `nil` — send nothing: thinking wasn't requested, the model doesn't
      reason, or it was switched off on a model that can't be switched off
    * `:off` — switch thinking off
    * `:dynamic` — on, and the model decides how much (`thinking: true`). A
      dialect with no native dynamic mode resolves `:medium` instead.
    * a map — on, with:
      * `:level` — the requested Omni level
      * `:effort` — the model's effort value for that level, or `nil` when
        the model lists no effort values
      * `:budget` — a token budget, or `nil` when the model takes none. Set
        when the model has a budget range, or no thinking data at all.

  On a model with no thinking data (`thinking: true`), `:effort` is `nil`
  and `:budget` is set; dialects fall back to their plain encoding of
  `:level`.
  """

  alias Omni.Model

  @ladder ~w(minimal low medium high xhigh max)
  @budgets %{low: 1024, medium: 4096, high: 16_384, xhigh: 24_576, max: 32_768}

  @typedoc "An Omni thinking level."
  @type level :: :low | :medium | :high | :xhigh | :max

  @typedoc "What a dialect should send for the `:thinking` option."
  @type t ::
          nil
          | :off
          | :dynamic
          | %{level: level(), effort: String.t() | nil, budget: non_neg_integer() | nil}

  @doc """
  Resolves a `:thinking` option value for a model.

      model = %Omni.Model{id: "gpt-oss", name: "gpt-oss", thinking: %{efforts: ["low", "medium", "high"]}}
      Omni.Dialect.Thinking.resolve(model, :max)
      #=> %{level: :max, effort: "high", budget: nil}
  """
  @spec resolve(Model.t(), term()) :: t()
  def resolve(%Model{thinking: false}, _option), do: nil
  def resolve(_model, nil), do: nil
  def resolve(model, false), do: if(switchable?(model), do: :off)
  def resolve(_model, true), do: :dynamic
  def resolve(model, level) when is_atom(level), do: on(model, level, nil)

  def resolve(model, %{} = option) do
    on(model, Map.get(option, :effort, :high), option[:budget])
  end

  @doc """
  Returns the default budget for a level, clamped to the model's budget range.
  """
  @spec budget(Model.t(), level()) :: non_neg_integer()
  def budget(%Model{} = model, level), do: clamp_budget(model, Map.fetch!(@budgets, level))

  # A model can be switched off when it has a toggle, lists "none", or
  # carries no data to say otherwise.
  defp switchable?(%Model{thinking: true}), do: true

  defp switchable?(%Model{thinking: thinking}) do
    Map.get(thinking, :toggle, false) or "none" in Map.get(thinking, :efforts, [])
  end

  defp on(%Model{thinking: thinking} = model, level, budget) do
    %{
      level: level,
      effort: effort(thinking, level),
      budget: if(budget?(thinking), do: clamp_budget(model, budget || @budgets[level]))
    }
  end

  defp budget?(true), do: true
  defp budget?(thinking), do: Map.has_key?(thinking, :budget)

  defp effort(true, _level), do: nil

  defp effort(thinking, level) do
    case Map.get(thinking, :efforts) do
      nil -> nil
      efforts -> clamp_effort(efforts, Atom.to_string(level))
    end
  end

  defp clamp_effort(efforts, level) do
    case Enum.filter(@ladder, &(&1 in efforts)) do
      [] ->
        if "default" in efforts, do: "default"

      supported ->
        index = Enum.find_index(@ladder, &(&1 == level))

        Enum.find(supported, &(ladder_index(&1) >= index)) || List.last(supported)
    end
  end

  defp ladder_index(value), do: Enum.find_index(@ladder, &(&1 == value))

  defp clamp_budget(%Model{thinking: %{budget: {min, max}}}, budget) do
    budget
    |> then(&if(is_integer(min), do: max(&1, min), else: &1))
    |> then(&if(is_integer(max), do: min(&1, max), else: &1))
  end

  defp clamp_budget(_model, budget), do: budget
end
