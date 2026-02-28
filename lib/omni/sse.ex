defmodule Omni.SSE do
  # Parses a stream of binary chunks into decoded SSE event maps.
  #
  # Accepts any enumerable yielding binary chunks (typically a `Req.Response.Async`)
  # and returns a lazy `Stream` yielding decoded JSON maps — one per SSE `data:` event.
  #
  # Follows the SSE specification:
  # https://html.spec.whatwg.org/multipage/server-sent-events.html
  #
  # Comment lines (`:`) are ignored, `event:` / `id:` / `retry:` fields are discarded,
  # multiple `data:` lines within one event are joined with "\n", and a `data: [DONE]`
  # sentinel halts the stream.
  @moduledoc false

  @doc """
  Transforms an enumerable of binary chunks into a stream of decoded JSON maps.

  Each yielded value is a map produced by `JSON.decode!/1` from the `data:` lines
  of a single SSE event. Events without data, comment-only events, and events
  whose data fails to decode are silently skipped.
  """
  @spec stream(Enumerable.t()) :: Enumerable.t()
  def stream(async_body) do
    async_body
    |> Stream.transform("", &process_chunk/2)
  end

  defp process_chunk(_chunk, :halt) do
    {:halt, :halt}
  end

  defp process_chunk(chunk, buffer) do
    # Normalize \r\n and bare \r to \n per the SSE spec
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
