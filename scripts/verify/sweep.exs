# Verifies a matrix of current models against their live APIs.
#
#     mix run scripts/verify/sweep.exs              # every provider with a key
#     mix run scripts/verify/sweep.exs zai openai   # just these providers
#
# Runs `Omni.Verify` on each model in turn, printing results as they land, and
# writes a markdown summary to scripts/verify/results/ (the newest 3 are kept).
# Providers without an API key are skipped. Requests are real and billed.
#
# Each entry is {provider, model, selection}. The model is a catalog id, or a
# keyword list of `Omni.Model.new/1` attributes for models the catalog lacks.
# The selection takes the same `only:`, `add:` and `skip:` as the task.
# The matrix tracks today's common models; update it as lineups change.

alias Omni.Verify

all = [add: [:image, :pdf, :kitchen_sink, :cache_usage]]
loop = [add: [:kitchen_sink]]

matrix = [
  {:anthropic, "claude-haiku-5-5", all},
  {:anthropic, "claude-opus-5-5", loop},
  {:openai, "gpt-6-luna", all},
  {:openai, "gpt-6-astra", loop},
  {:google, "gemini-3.8-flash", all},
  {:google, "gemini-3.5-flash-lite", []},
  {:groq, "openai/gpt-oss-120b", loop},
  {:groq, "qwen/qwen3.8-27b", add: [:image]},
  {:moonshotai, "kimi-k2.6", add: [:image, :kitchen_sink, :cache_usage]},
  {:alibaba, "qwen3.8-flash", add: [:image, :kitchen_sink, :cache_usage]},
  {:alibaba, "qwen3.8-max", add: [:pdf]},
  {:zai, "glm-5.3-flash", add: [:image, :pdf, :kitchen_sink, :cache_usage]},
  {:zai, "glm-4.7-flash", []},
  {:venice, "qwen-3-8-flash", add: [:image, :pdf, :kitchen_sink]},
  {:venice, "claude-haiku-5-5", []},
  {:nearai, "zai-org/GLM-5.1-FP8", []},
  {:ollama_cloud, "deepseek-v4.1-flash", loop},
  {:ollama_cloud, "glm-5.3-flash", add: [:image]},
  {:ollama, [id: "qwen3.8:27b-mlx", thinking: true, input_modalities: [:text, :image]],
   add: [:image, :kitchen_sink]},
  {:opencode, "claude-haiku-5-5", []},
  {:opencode, "gpt-6-luna", []},
  {:opencode, "deepseek-v4.1-flash", []},
  {:opencode, "gemini-3.5-flash-lite", []},
  {:openrouter, "anthropic/claude-haiku-5.5", loop},
  {:openrouter, "openai/gpt-6-luna", loop},
  {:openrouter, "google/gemini-3.8-flash", loop},
  {:openrouter, "deepseek/deepseek-v4.1-flash", loop}
]

results_dir = Path.join(__DIR__, "results")
keep = 3
delay = 1_000

defmodule Sweep do
  # Why a provider can't be swept, or nil when it can.
  def unavailable(provider_id) do
    case Omni.get_provider(provider_id) do
      {:error, _} ->
        "not loaded"

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
    model = attrs |> Keyword.put(:provider, provider_id) |> Keyword.put_new(:name, attrs[:id]) |> Omni.Model.new()
    :ok = Omni.put_model(model)
    {:ok, model}
  end

  def model(provider_id, model_id), do: Omni.get_model(provider_id, model_id)

  def label(provider_id, attrs) when is_list(attrs), do: "#{provider_id}/#{attrs[:id]}"
  def label(provider_id, model_id), do: "#{provider_id}/#{model_id}"
end

Logger.configure(level: :info)

only_providers = Enum.map(System.argv(), &String.to_atom/1)

matrix =
  if only_providers == [],
    do: matrix,
    else: Enum.filter(matrix, fn {provider, _, _} -> provider in only_providers end)

skipped =
  matrix
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
  for {provider, model_ref, selection} <- matrix, not Map.has_key?(skipped, provider) do
    label = Sweep.label(provider, model_ref)
    IO.puts("\n#{label}")

    with {:ok, scenarios} <- Verify.select(selection),
         {:ok, model} <- Sweep.model(provider, model_ref) do
      results =
        Verify.run(model, scenarios, delay: delay, on_result: &IO.puts(Verify.format_line(&1)))

      results
      |> Enum.filter(&(&1.status == :fail))
      |> Enum.each(&IO.puts(Verify.format_failure(&1)))

      {label, {:ok, results}}
    else
      {:error, reason} ->
        IO.puts("  ✗ #{inspect(reason)}")
        {label, {:error, reason}}
    end
  end

for {provider, reason} <- skipped, do: IO.puts("\nskipped #{provider}: #{reason}")

# -- Results file --

columns =
  Enum.filter(Verify.scenarios(), fn scenario ->
    Enum.any?(runs, fn
      {_, {:ok, results}} -> Enum.any?(results, &(&1.scenario == scenario))
      _ -> false
    end)
  end)

cell = fn results, scenario ->
  case Enum.find(results, &(&1.scenario == scenario)) do
    %{status: :pass} -> "✓"
    %{status: :fail} -> "✗"
    nil -> ""
  end
end

rows =
  Enum.map(runs, fn
    {label, {:ok, results}} ->
      "| #{label} | " <> Enum.map_join(columns, " | ", &cell.(results, &1)) <> " |"

    {label, {:error, reason}} ->
      "| #{label} | " <> Enum.map_join(columns, " | ", fn _ -> "—" end) <> " | #{inspect(reason)}"
  end)

failures =
  for {label, {:ok, results}} <- runs, %{status: :fail} = result <- results do
    "- **#{label}** `#{result.scenario}`: #{String.replace(result.error, "\n", " ")}"
  end

now = DateTime.utc_now()
all_results = for {_, {:ok, results}} <- runs, result <- results, do: result

report = """
# Verification sweep — #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC

Omni #{Application.spec(:omni, :vsn)}. #{Enum.count(all_results, &(&1.status == :pass))} passed, \
#{Enum.count(all_results, &(&1.status == :fail))} failed across #{length(runs)} models.

| Model | #{Enum.join(columns, " | ")} |
|---|#{Enum.map_join(columns, "", fn _ -> "---|" end)}
#{Enum.join(rows, "\n")}

## Failures

#{if failures == [], do: "None.", else: Enum.join(failures, "\n")}

## Skipped

#{if skipped == %{}, do: "None.", else: Enum.map_join(skipped, "\n", fn {p, reason} -> "- #{p}: #{reason}" end)}
"""

File.mkdir_p!(results_dir)
results_file = Path.join(results_dir, Calendar.strftime(now, "%Y-%m-%d-%H%M") <> ".md")
File.write!(results_file, report)

results_dir
|> Path.join("*.md")
|> Path.wildcard()
|> Enum.sort(:desc)
|> Enum.drop(keep)
|> Enum.each(&File.rm!/1)

IO.puts("\nWrote #{Path.relative_to_cwd(results_file)}")
