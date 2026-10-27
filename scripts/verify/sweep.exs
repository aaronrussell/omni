# Verifies a matrix of current models against their live APIs.
#
#     mix run scripts/verify/sweep.exs                          # the whole matrix
#     mix run scripts/verify/sweep.exs zai openai               # these providers' entries
#     mix run scripts/verify/sweep.exs zai/glm-4.7-flash        # one model
#     mix run scripts/verify/sweep.exs zai/glm-4.7-flash --only text,tool_use
#     mix run scripts/verify/sweep.exs moonshotai --delay 20000
#
# Runs `Omni.Verify` on each model in turn, printing results as they land, with
# full errors after each model. Requests are real and billed. Providers without
# an API key are skipped.
#
# A target is a provider or provider/model. A model the matrix doesn't list is
# looked up in the catalog and runs the default scenarios. `--only` replaces
# the selection of every target, so it can run scenarios the matrix leaves out.
# `--delay ms` sets the pause between scenarios (default 1000), for rate limits.
#
# Results accumulate by day in scripts/verify/results/YYYY-MM-DD.json: each run
# overwrites the cells it ran and keeps the rest, and the markdown view beside
# it is regenerated. Only generic results are saved, never provider errors.
# Old days are kept until deleted by hand. A run that tests nothing (say, a
# provider without a key) still regenerates the markdown, so the JSON can be
# edited by hand.
#
# Each entry is {provider, model, selection}. The model is a catalog id, or a
# keyword list of `Omni.Model.new/1` attributes for models the catalog lacks.
# The selection takes the same `only:`, `add:` and `skip:` as the task.
# The matrix tracks today's common models; update it as lineups change.

alias Omni.Verify

# `no_thinking` only goes on models whose data says they can switch off (a
# toggle or a "none" effort); elsewhere Omni sends nothing for `thinking: false`.
all = [add: [:no_thinking, :image, :pdf, :kitchen_sink, :cache_usage]]
loop = [add: [:kitchen_sink]]
loop_off = [add: [:no_thinking, :kitchen_sink]]
off = [add: [:no_thinking]]

matrix = [
  {:anthropic, "claude-haiku-5-5", all},
  {:anthropic, "claude-opus-5-5", loop},
  {:openai, "gpt-6-luna", all},
  {:openai, "gpt-6-astra", loop},
  # Gemini's implicit cache never reported a hit in testing, even 60s apart.
  {:google, "gemini-3.8-flash", add: [:image, :pdf, :kitchen_sink]},
  {:google, "gemini-3.5-flash-lite", []},
  {:groq, "openai/gpt-oss-120b", loop},
  {:groq, "qwen/qwen3.8-27b", add: [:no_thinking, :image]},
  {:moonshotai, "kimi-k3", add: [:image, :kitchen_sink, :cache_usage]},
  # The free tier serves Ministral only; Mistral's reasoning models run
  # through OpenCode Zen, which passes Mistral's wire through.
  {:mistral, "ministral-8b-2512", add: [:image], skip: [:thinking]},
  {:alibaba, "qwen3.8-flash", add: [:no_thinking, :image, :kitchen_sink, :cache_usage]},
  {:alibaba, "qwen3.8-max", add: [:no_thinking, :pdf]},
  {:zai, "glm-5.3-flash", add: [:image, :pdf, :kitchen_sink, :cache_usage]},
  {:zai, "glm-4.7-flash", off},
  {:venice, "qwen-3-8-flash", add: [:no_thinking, :image, :pdf, :kitchen_sink]},
  {:venice, "claude-haiku-5-5", off},
  {:nearai, "zai-org/GLM-5.1-FP8", off},
  # Fails structured_output: Ollama Cloud doesn't enforce `format` (gemma4 and
  # gpt-oss:20b answer in prose; local Ollama passes). Kept as a known failure.
  {:ollama_cloud, "gemma4:31b", add: [:no_thinking, :image, :kitchen_sink]},
  {:ollama, [id: "qwen3.8:27b-mlx", thinking: true, input_modalities: [:text, :image]],
   add: [:no_thinking, :image, :kitchen_sink]},
  {:opencode, "claude-haiku-5-5", off},
  {:opencode, "gpt-6-luna", off},
  {:opencode, "deepseek-v4.1-flash", []},
  {:opencode, "mistral-large-4", add: [:no_thinking, :image, :kitchen_sink]},
  {:opencode, "gemini-3.5-flash-lite", []},
  {:openrouter, "anthropic/claude-haiku-5.5", loop_off},
  {:openrouter, "openai/gpt-6-luna", loop_off},
  {:openrouter, "google/gemini-3.8-flash", loop},
  {:openrouter, "deepseek/deepseek-v4.1-flash", loop_off}
]

results_dir = Path.join(__DIR__, "results")

defmodule Sweep do
  # Why a provider can't be swept, or nil when it can. A catalog provider
  # that isn't loaded is loaded, as the task does.
  def unavailable(provider_id) do
    case Omni.get_provider(provider_id) do
      {:error, _} ->
        try do
          Omni.Provider.load([provider_id])
          unavailable(provider_id)
        rescue
          ArgumentError -> "not a known provider"
        end

      {:ok, %{auth: :none} = provider} ->
        case Req.get(provider.base_url, receive_timeout: 1_000, retry: false) do
          {:ok, _} -> nil
          {:error, _} -> "not reachable at #{provider.base_url}"
        end

      {:ok, provider} ->
        case Omni.Provider.resolve_auth(provider.api_key) do
          {:ok, _} -> nil
          {:error, {:missing_env_var, var}} -> "#{var} not set"
          {:error, _} -> "no API key"
        end
    end
  end

  def model(provider_id, attrs) when is_list(attrs) do
    model =
      attrs
      |> Keyword.put(:provider, provider_id)
      |> Keyword.put_new(:name, attrs[:id])
      |> Omni.Model.new()

    :ok = Omni.put_model(model)
    {:ok, model}
  end

  def model(provider_id, model_id), do: Omni.get_model(provider_id, model_id)

  def label(provider_id, attrs) when is_list(attrs), do: "#{provider_id}/#{attrs[:id]}"
  def label(provider_id, model_id), do: "#{provider_id}/#{model_id}"

  # Matrix entries for each target, in target order. Model ids can hold
  # slashes, so only the first one splits a target.
  def entries(matrix, []), do: matrix

  def entries(matrix, targets) do
    targets
    |> Enum.flat_map(fn target ->
      case String.split(target, "/", parts: 2) do
        [provider] ->
          Enum.filter(matrix, fn {p, _, _} -> Atom.to_string(p) == provider end)

        [provider, model_id] ->
          case Enum.filter(matrix, fn {p, ref, _} -> label(p, ref) == target end) do
            [] -> [{String.to_atom(provider), model_id, []}]
            found -> found
          end
      end
    end)
    |> Enum.uniq()
  end

  def scenario_list(value) do
    known = Map.new(Omni.Verify.scenarios(), &{Atom.to_string(&1), &1})

    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Map.get(known, &1, &1))
  end

  # -- Results --

  def load(json_file) do
    case File.read(json_file) do
      {:ok, json} -> Jason.decode!(json)["models"]
      {:error, :enoent} -> %{}
    end
  end

  def cell(result) do
    %{
      "status" => Atom.to_string(result.status),
      "result" => result.summary,
      "time_ms" => result.time_ms
    }
  end

  # Matrix order first, then models from outside it, alphabetically;
  # scenarios in run order. Ordered objects keep the file diffable.
  def encode(models, date, matrix) do
    data =
      Jason.OrderedObject.new([
        {"date", Date.to_iso8601(date)},
        {"omni", to_string(Application.spec(:omni, :vsn))},
        {"models",
         Jason.OrderedObject.new(
           for label <- model_order(models, matrix) do
             {label,
              Jason.OrderedObject.new(
                for scenario <- scenario_order(models[label]) do
                  cell = models[label][scenario]

                  {scenario,
                   Jason.OrderedObject.new(
                     for key <- ["status", "result", "time_ms"], do: {key, cell[key]}
                   )}
                end
              )}
           end
         )}
      ])

    Jason.encode!(data, pretty: true) <> "\n"
  end

  def model_order(models, matrix) do
    in_matrix =
      for {p, ref, _} <- matrix, label = label(p, ref), Map.has_key?(models, label), do: label

    in_matrix ++ Enum.sort(Map.keys(models) -- in_matrix)
  end

  def scenario_order(cells) do
    known = Enum.map(Omni.Verify.scenarios(), &Atom.to_string/1)
    Enum.filter(known, &Map.has_key?(cells, &1)) ++ Enum.sort(Map.keys(cells) -- known)
  end

  def markdown(models, date, matrix) do
    labels = model_order(models, matrix)
    columns = models |> Map.values() |> Enum.reduce(%{}, &Map.merge/2) |> scenario_order()
    cells = for label <- labels, {_, cell} <- models[label], do: cell
    count = fn status -> Enum.count(cells, &(&1["status"] == status)) end

    rows =
      for label <- labels do
        "| #{label} | " <> Enum.map_join(columns, " | ", &mark(models[label][&1])) <> " |"
      end

    failures =
      for label <- labels,
          scenario <- columns,
          cell = models[label][scenario],
          cell && cell["status"] == "fail",
          do: "- **#{label}** `#{scenario}`: #{cell["result"]}"

    """
    # Verification sweep — #{Date.to_iso8601(date)}

    Omni #{Application.spec(:omni, :vsn)}. #{count.("pass")} passed, #{count.("fail")} failed \
    across #{length(labels)} models.

    | Model | #{Enum.join(columns, " | ")} |
    |---|#{Enum.map_join(columns, "", fn _ -> "---|" end)}
    #{Enum.join(rows, "\n")}

    ## Failures

    #{if failures == [], do: "None.", else: Enum.join(failures, "\n")}
    """
  end

  defp mark(nil), do: ""

  defp mark(%{"status" => "pass"}), do: "✓"
  defp mark(_cell), do: "✗"
end

Logger.configure(level: :info)

{opts, targets} = OptionParser.parse!(System.argv(), strict: [only: :string, delay: :integer])
delay = Keyword.get(opts, :delay, 1_000)

entries =
  for {provider, model_ref, selection} <- Sweep.entries(matrix, targets) do
    selection = if opts[:only], do: [only: Sweep.scenario_list(opts[:only])], else: selection
    {provider, model_ref, selection}
  end

skipped =
  entries
  |> Enum.map(fn {provider, _, _} -> provider end)
  |> Enum.uniq()
  |> Enum.flat_map(fn provider ->
    case Sweep.unavailable(provider) do
      nil -> []
      reason -> [{provider, reason}]
    end
  end)
  |> Map.new()

runs =
  for {provider, model_ref, selection} <- entries, not Map.has_key?(skipped, provider) do
    label = Sweep.label(provider, model_ref)
    IO.puts("\n#{label}")

    with {:ok, scenarios} <- Verify.select(selection),
         {:ok, model} <- Sweep.model(provider, model_ref) do
      results =
        Verify.run(model, scenarios, delay: delay, on_result: &IO.puts(Verify.format_line(&1)))

      results
      |> Enum.flat_map(&List.wrap(Verify.format_failure(&1)))
      |> Enum.each(&IO.puts/1)

      [{label, results}]
    else
      {:error, reason} ->
        IO.puts("  ✗ #{inspect(reason)}")
        []
    end
  end
  |> Enum.concat()

for {provider, reason} <- skipped, do: IO.puts("\nskipped #{provider}: #{reason}")

{{year, month, day}, _} = :calendar.local_time()
date = Date.new!(year, month, day)
json_file = Path.join(results_dir, "#{date}.json")

models =
  Enum.reduce(runs, Sweep.load(json_file), fn {label, results}, models ->
    cells = Map.new(results, &{Atom.to_string(&1.scenario), Sweep.cell(&1)})
    Map.update(models, label, cells, &Map.merge(&1, cells))
  end)

if models != %{} do
  File.mkdir_p!(results_dir)
  File.write!(json_file, Sweep.encode(models, date, matrix))
  File.write!(Path.rootname(json_file) <> ".md", Sweep.markdown(models, date, matrix))
  IO.puts("\nUpdated #{Path.relative_to_cwd(Path.rootname(json_file))}.{json,md}")
end
