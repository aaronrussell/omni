defmodule Omni.Dialect.Decision.Answers do
  @moduledoc false
  # Shared answer matching for decision dialects. Each dialect indexes its
  # wire answers by question name (a string) and decodes one answer at a
  # time; this module applies the one strict rule: every question has
  # exactly one answer of its type, and no answer is for a question that
  # wasn't asked. Probabilities map back to the caller's keys, in the
  # caller's order. Numbers come back as floats: hosts send `1` and `0` as
  # JSON integers.

  alias Omni.Question

  @doc false
  # `by_name` maps question name strings to wire answers; `decode` turns one
  # (question, wire answer) into `{:ok, answer}` or `:error`.
  @spec decode([{atom(), Question.t()}], %{String.t() => map()}, (Question.t(), map() ->
                                                                    {:ok, term()} | :error)) ::
          {:ok, [{atom(), term()}]} | {:error, {:invalid_answer, atom() | String.t()}}
  def decode(questions, by_name, decode) do
    names = Enum.map(questions, fn {name, _question} -> Atom.to_string(name) end)

    case Enum.find(Map.keys(by_name), &(&1 not in names)) do
      nil -> decode_each(questions, by_name, decode)
      extra -> {:error, {:invalid_answer, extra}}
    end
  end

  defp decode_each(questions, by_name, decode) do
    questions
    |> Enum.reduce_while([], fn {name, question}, acc ->
      with %{} = wire <- Map.get(by_name, Atom.to_string(name)),
           {:ok, answer} <- decode.(question, wire) do
        {:cont, [{name, answer} | acc]}
      else
        _ -> {:halt, {:error, {:invalid_answer, name}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      answers -> {:ok, Enum.reverse(answers)}
    end
  end

  @doc false
  # The caller's key for a wire choice string.
  @spec key([Question.option()], term()) :: {:ok, Question.key()} | :error
  def key(options, wire) when is_binary(wire) do
    case Enum.find(options, fn {key, _desc} -> to_string(key) == wire end) do
      {key, _desc} -> {:ok, key}
      nil -> :error
    end
  end

  def key(_options, _wire), do: :error

  @doc false
  # `{key, probability}` for every option, in order. The wire map is keyed by
  # the option's key as a string (`:key`) or by its index as a string
  # (`:index`). Every option must have a number.
  @spec probabilities([Question.option()], term(), :key | :index) ::
          {:ok, [{Question.key(), float()}]} | :error
  def probabilities(options, wire, by) when is_map(wire) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {{key, _desc}, index}, acc ->
      wire_key = if by == :key, do: to_string(key), else: Integer.to_string(index)

      case Map.get(wire, wire_key) do
        p when is_number(p) -> {:cont, [{key, float(p)} | acc]}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      pairs -> {:ok, Enum.reverse(pairs)}
    end
  end

  def probabilities(_options, _wire, _by), do: :error

  @doc false
  # A wire number as a float; anything else (an absent confidence) is `nil`.
  @spec float(term()) :: float() | nil
  def float(number) when is_number(number), do: number * 1.0
  def float(_other), do: nil
end
