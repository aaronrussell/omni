defmodule Omni.Verify do
  @moduledoc false

  # Runs live verification scenarios against a model. Backs `mix omni.verify`
  # and the sweep script; see `Mix.Tasks.Omni.Verify` for what each scenario
  # checks.

  alias Omni.Model
  alias Omni.Verify.Scenarios

  @scenarios [
    :text,
    :thinking,
    :no_thinking,
    :tool_use,
    :structured_output,
    :image,
    :pdf,
    :kitchen_sink,
    :cache_usage
  ]

  @defaults [:text, :thinking, :no_thinking, :tool_use, :structured_output]

  @default_timeout 120_000

  @type result :: %{
          scenario: atom(),
          status: :pass | :fail,
          time_ms: non_neg_integer(),
          summary: String.t() | nil,
          error: String.t() | nil,
          request: map() | nil
        }

  @doc "All scenario names, in run order."
  @spec scenarios() :: [atom()]
  def scenarios, do: @scenarios

  @doc "The scenarios run when none are selected."
  @spec defaults() :: [atom()]
  def defaults, do: @defaults

  @doc """
  Selects scenarios. `:only` gives the exact list; otherwise the defaults,
  plus `:add`, minus `:skip`. The result keeps run order.
  """
  @spec select(keyword()) :: {:ok, [atom()]} | {:error, {:unknown_scenarios, [atom()]}}
  def select(opts \\ []) do
    only = Keyword.get(opts, :only)
    add = Keyword.get(opts, :add, [])
    skip = Keyword.get(opts, :skip, [])

    case Enum.reject(List.wrap(only) ++ add ++ skip, &(&1 in @scenarios)) do
      [] ->
        chosen = if only, do: only, else: (@defaults ++ add) -- skip
        {:ok, Enum.filter(@scenarios, &(&1 in chosen))}

      unknown ->
        {:error, {:unknown_scenarios, Enum.uniq(unknown)}}
    end
  end

  @doc """
  Runs scenarios against a model, one at a time, and returns their results.

  ## Options

    * `:delay` — milliseconds to pause between scenarios (default `0`)
    * `:on_result` — a 1-arity function called with each result as it lands

  Other options pass through to `Omni.generate_text/3` (for example
  `:api_key` or `:plug`). `:timeout` defaults to two minutes.
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
      result = run_scenario(scenario, model, opts)
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
    detail = if result.status == :pass, do: result.summary, else: result.error
    "  #{mark} #{name} #{time}  #{detail}"
  end

  @doc "Formats a failed result with its request body, long strings cut short."
  @spec format_failure(result()) :: String.t()
  def format_failure(result) do
    request =
      case result.request do
        nil -> "(not built)"
        body -> body |> truncate() |> inspect(pretty: true, limit: :infinity, width: 90)
      end

    "\n  #{result.scenario}: #{result.error}\n" <>
      "    request: " <> String.replace(request, "\n", "\n             ")
  end

  # Keeps base64 attachments and long prompts from flooding the report.
  defp truncate(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, truncate(v)} end)
  defp truncate(value) when is_list(value), do: Enum.map(value, &truncate/1)

  defp truncate(value) when is_binary(value) and byte_size(value) > 200,
    do: String.slice(value, 0, 60) <> "… (#{byte_size(value)} bytes)"

  defp truncate(value), do: value

  defp run_scenario(scenario, model, opts) do
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        Scenarios.run(scenario, model, opts)
      rescue
        e -> {:fail, "raised " <> Exception.format_banner(:error, e, __STACKTRACE__), nil}
      catch
        kind, reason -> {:fail, Exception.format_banner(kind, reason, __STACKTRACE__), nil}
      end

    time_ms = System.monotonic_time(:millisecond) - started
    result = %{scenario: scenario, time_ms: time_ms, summary: nil, error: nil, request: nil}

    case outcome do
      {:pass, summary} ->
        Map.merge(result, %{status: :pass, summary: summary})

      {:fail, error, request} ->
        Map.merge(result, %{status: :fail, error: error, request: request})
    end
  end
end
