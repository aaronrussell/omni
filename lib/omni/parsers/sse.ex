defmodule Omni.Parsers.SSE do
  @moduledoc false

  # Parses a stream of binary chunks into decoded SSE events.
  #
  # Follows the SSE specification, as far as LLM APIs use it:
  # https://html.spec.whatwg.org/multipage/server-sent-events.html
  #
  # Only `data:` lines are read. Comment lines and the `event:`, `id:` and
  # `retry:` fields are discarded, the `data:` lines of one event are joined
  # with "\n", and a `data: [DONE]` sentinel halts the stream.

  @doc """
  Transforms an enumerable of binary chunks into a stream of decoded JSON maps.

  Takes any enumerable of binaries, typically a `Req.Response.Async`, and
  yields one map per SSE event. Events without data, and events whose data
  fails to decode, are skipped.
  """
  @spec stream(Enumerable.t()) :: Enumerable.t()
  def stream(async_body) do
    Stream.transform(
      async_body,
      fn -> "" end,
      &process_chunk/2,
      fn
        :halt ->
          {[], :halt}

        "" ->
          {[], ""}

        buffer ->
          case parse_event(buffer) do
            :halt -> {[], :halt}
            :skip -> {[], ""}
            {:ok, decoded} -> {[decoded], ""}
          end
      end,
      fn _acc -> :ok end
    )
  end

  defp process_chunk(_chunk, :halt) do
    {:halt, :halt}
  end

  defp process_chunk(chunk, buffer) do
    # The spec allows \r\n and bare \r as line endings.
    normalized = String.replace(buffer <> chunk, "\r\n", "\n") |> String.replace("\r", "\n")

    case extract_events(normalized, []) do
      {:emit, events, new_buffer} -> {events, new_buffer}
      {:halt, events} -> {events, :halt}
    end
  end

  defp extract_events(buffer, acc) do
    case :binary.split(buffer, "\n\n") do
      [^buffer] ->
        {:emit, Enum.reverse(acc), buffer}

      [event_text, rest] ->
        case parse_event(event_text) do
          :halt -> {:halt, Enum.reverse(acc)}
          :skip -> extract_events(rest, acc)
          {:ok, decoded} -> extract_events(rest, [decoded | acc])
        end
    end
  end

  defp parse_event(event_text) do
    data_lines =
      event_text
      |> String.split("\n")
      |> Enum.reduce([], fn line, acc ->
        case line do
          "data: " <> value -> [value | acc]
          "data:" <> value -> [value | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    case data_lines do
      [] ->
        :skip

      lines ->
        joined = Enum.join(lines, "\n")

        cond do
          joined == "[DONE]" -> :halt
          joined == "" -> :skip
          true -> decode(joined)
        end
    end
  end

  defp decode(data) do
    case JSON.decode(data) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> :skip
    end
  end
end
