defmodule Omni.Verify do
  @moduledoc false

  # Runs live verification scenarios against a model. Backs `mix omni.verify`
  # and the sweep script; see `Mix.Tasks.Omni.Verify` for what each scenario
  # checks.

  alias Omni.Model
  alias Omni.Verify.Scenarios

  # Scenarios by the capability they test, in run order. A model's defaults
  # are the defaults of every capability it has.
  @scenarios [
    text: [
      :text,
      :thinking,
      :no_thinking,
      :tool_use,
      :structured_output,
      :image,
      :pdf,
      :kitchen_sink,
      :cache_usage
    ],
    decision: [:decision, :decision_json]
  ]

  @defaults [
    text: [:text, :thinking, :tool_use, :structured_output],
    decision: [:decision, :decision_json]
  ]

  @default_timeout 120_000

  # Bounds a runaway generation (JSON mode can stream whitespace to the token
  # limit), with room for thinking models.
  @default_max_tokens 8_192

  # `summary` is one short line: an excerpt of the answer on a pass, a generic
  # reason on a failure, so it is safe to save. `error` holds the full detail
  # behind a failure (a provider error, a stacktrace) for the terminal only.
  @type result :: %{
          scenario: atom(),
          status: :pass | :fail,
          time_ms: non_neg_integer(),
          summary: String.t(),
          error: String.t() | nil
        }

  @doc "All scenario names, in run order."
  @spec scenarios() :: [atom()]
  def scenarios, do: Enum.flat_map(@scenarios, &elem(&1, 1))

  @doc "The scenarios run on a model when none are selected: those of each of its capabilities."
  @spec defaults(Model.t()) :: [atom()]
  def defaults(%Model{} = model) do
    capabilities = Model.capabilities(model)

    Enum.flat_map(@defaults, fn {cap, scenarios} ->
      if cap in capabilities, do: scenarios, else: []
    end)
  end

  @doc """
  Selects scenarios for a model.

  `:only` gives the exact list; otherwise the model's defaults, plus `:add`,
  minus `:skip`. The result keeps run order.
  """
  @spec select(Model.t(), keyword()) ::
          {:ok, [atom()]} | {:error, {:unknown_scenarios, [atom()]}}
  def select(%Model{} = model, opts \\ []) do
    only = Keyword.get(opts, :only)
    add = Keyword.get(opts, :add, [])
    skip = Keyword.get(opts, :skip, [])
    all = scenarios()

    case Enum.reject(List.wrap(only) ++ add ++ skip, &(&1 in all)) do
      [] ->
        chosen = if only, do: only, else: (defaults(model) ++ add) -- skip
        {:ok, Enum.filter(all, &(&1 in chosen))}

      unknown ->
        {:error, {:unknown_scenarios, Enum.uniq(unknown)}}
    end
  end

  @doc """
  Runs scenarios against a model, one at a time, and returns their results.

  ## Options

  - `:delay` - milliseconds to pause between scenarios (default `0`)
  - `:on_result` - a 1-arity function called with each result as it lands

  Other options pass through to `Omni.generate_text/3` or `Omni.decide/3`
  (for example `:api_key` or `:plug`). `:timeout` (the longest wait for a
  response or each chunk) defaults to two minutes, and `:max_tokens` to 8192
  on text scenarios.
  """
  @spec run(Model.t(), [atom()], keyword()) :: [result()]
  def run(%Model{} = model, scenarios, opts \\ []) do
    {delay, opts} = Keyword.pop(opts, :delay, 0)
    {on_result, opts} = Keyword.pop(opts, :on_result, fn _ -> :ok end)

    opts = Keyword.put_new(opts, :timeout, @default_timeout)

    scenarios
    |> Enum.with_index()
    |> Enum.map(fn {scenario, index} ->
      if index > 0 and delay > 0, do: Process.sleep(delay)
      result = run_scenario(scenario, model, scenario_opts(scenario, opts))
      on_result.(result)
      result
    end)
  end

  @doc "Formats a result as one report line."
  @spec format_line(result()) :: String.t()
  def format_line(result) do
    mark = if result.status == :pass, do: "✓", else: "✗"
    name = result.scenario |> Atom.to_string() |> String.pad_trailing(18)
    time = :io_lib.format("~5.1fs", [result.time_ms / 1000]) |> to_string()
    "  #{mark} #{name} #{time}  #{result.summary}"
  end

  @doc "Formats a failure's full error, or nil when the summary says it all."
  @spec format_failure(result()) :: String.t() | nil
  def format_failure(%{error: nil}), do: nil

  def format_failure(result) do
    "\n  #{result.scenario}: #{result.summary}\n    " <>
      String.replace(result.error, "\n", "\n    ")
  end

  # `max_tokens` is a text option; `Omni.decide/3` rejects it.
  defp scenario_opts(scenario, opts) do
    if scenario in @scenarios[:text],
      do: Keyword.put_new(opts, :max_tokens, @default_max_tokens),
      else: opts
  end

  defp run_scenario(scenario, model, opts) do
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        Scenarios.run(scenario, model, opts)
      rescue
        e ->
          {:fail, "raised #{inspect(e.__struct__)}", Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:fail, "#{kind}", Exception.format(kind, reason, __STACKTRACE__)}
      end

    time_ms = System.monotonic_time(:millisecond) - started
    result = %{scenario: scenario, time_ms: time_ms, error: nil}

    case outcome do
      {:pass, summary} ->
        Map.merge(result, %{status: :pass, summary: summary})

      {:fail, summary, error} ->
        Map.merge(result, %{status: :fail, summary: summary, error: error})
    end
  end
end
