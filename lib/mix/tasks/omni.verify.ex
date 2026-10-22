defmodule Mix.Tasks.Omni.Verify do
  @shortdoc "Verifies a model against its provider's live API"

  @moduledoc """
  Runs a set of live scenarios against one model and reports which pass.

      mix omni.verify anthropic claude-haiku-4-5
      mix omni.verify openai gpt-5-mini --add image,pdf
      mix omni.verify fireworks_ai accounts/fireworks/models/kimi-k3 --only text,tool_use

  Use it to check a provider before relying on it: a catalog provider Omni
  doesn't verify, a custom provider from your config, or a new model on a
  built-in. Requests are real and billed, using the provider's configured API
  key, and capped at 8192 output tokens so a runaway generation fails with
  `:length` instead of running on. Every selected scenario runs, even after a failure. Each result line
  gives a short reason for a failure, and failures from an error (an HTTP
  status, a crash) are followed by the full error. The task exits non-zero if
  any scenario fails.

  The task starts your application, so providers and models from your
  `config :omni` are available. A catalog provider that isn't loaded is
  loaded for the run.

  ## Scenarios

  Run by default:

    * `text` — a short prompt; passes on a `:stop` response with text
    * `thinking` — a reasoning question with `thinking: :low`; passes when
      the response shows thinking (text, a signature, or redacted data)
    * `tool_use` — a weather tool without a handler; passes on a
      `get_weather` tool use for London
    * `structured_output` — an object schema via `:output`; passes when the
      output matches it

  Run on request:

    * `no_thinking` — the reasoning question with `thinking: false`; passes
      when no thinking comes back. Only meaningful on a model whose data says
      it can switch thinking off: on one that can't, Omni sends nothing and
      the model reasons as usual.
    * `image` — a PNG logo; passes when the answer names the brand
    * `pdf` — a one-page PDF; passes when the answer names the author
    * `kitchen_sink` — two tools with handlers and `thinking: :low`, run
      through the tool loop, then a follow-up turn over the whole history;
      passes when both turns finish with text after at least one tool round
    * `cache_usage` — a long system prompt with `cache: :short`, then a
      second turn on top of the first; passes when the second turn reports
      cache-read tokens

  A scenario a model doesn't support fails; select the ones that apply.

  ## Options

    * `--only a,b` — run exactly these scenarios
    * `--add a,b` — run these as well as the defaults
    * `--skip a,b` — leave these out of the defaults
    * `--delay ms` — pause between scenarios, for rate-limited accounts
  """

  use Mix.Task

  alias Omni.Verify

  @switches [only: :string, add: :string, skip: :string, delay: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = parse!(args)

    [provider_arg, model_id] =
      case positional do
        [_provider, _model] = pair -> pair
        _ -> Mix.raise("Usage: mix omni.verify <provider> <model> [options]")
      end

    scenarios = select!(opts)

    # Catalog loading logs a debug line per provider; keep the report readable.
    Logger.configure(level: :info)
    Mix.Task.run("app.start")

    provider_id = String.to_atom(provider_arg)
    ensure_provider!(provider_id)

    model =
      case Omni.get_model(provider_id, model_id) do
        {:ok, model} ->
          model

        {:error, _} ->
          Mix.raise(
            "Unknown model #{provider_id}/#{model_id}. Models the catalog doesn't list " <>
              "can be added with `models:` in `config :omni, :providers`."
          )
      end

    shell = Mix.shell()
    shell.info("Verifying #{provider_id}/#{model_id} (#{inspect(model.dialects[:text])})\n")

    results =
      Verify.run(model, scenarios,
        delay: Keyword.get(opts, :delay, 0),
        on_result: &shell.info(Verify.format_line(&1))
      )

    failures = Enum.filter(results, &(&1.status == :fail))

    case Enum.flat_map(failures, &List.wrap(Verify.format_failure(&1))) do
      [] -> :ok
      errors -> shell.info(Enum.join(["\nErrors" | errors], "\n"))
    end

    passed = length(results) - length(failures)
    shell.info("\n#{passed} passed, #{length(failures)} failed")

    if failures != [], do: exit({:shutdown, 1})
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} -> {opts, positional}
      {_, _, invalid} -> Mix.raise("Unknown options: #{inspect(invalid)}")
    end
  end

  defp select!(opts) do
    selection =
      for key <- [:only, :add, :skip], value = opts[key], do: {key, split(value)}

    case Verify.select(selection) do
      {:ok, []} ->
        Mix.raise("No scenarios selected")

      {:ok, scenarios} ->
        scenarios

      {:error, {:unknown_scenarios, unknown}} ->
        Mix.raise(
          "Unknown scenarios: #{Enum.join(unknown, ", ")}. " <>
            "Available: #{Enum.join(Verify.scenarios(), ", ")}"
        )
    end
  end

  # Scenario names are matched against the known atoms, so unknown input never
  # becomes an atom.
  defp split(value) do
    known = Map.new(Verify.scenarios(), &{Atom.to_string(&1), &1})

    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Map.get(known, &1, &1))
  end

  defp ensure_provider!(id) do
    case Omni.get_provider(id) do
      {:ok, _provider} ->
        :ok

      {:error, _} ->
        try do
          Omni.Provider.load([id])
        rescue
          e in ArgumentError -> Mix.raise("Can't load provider #{id}: #{Exception.message(e)}")
        end
    end
  end
end
