defmodule Omni.Parsers.NDJSON do
  @moduledoc false

  # Parses a stream of binary chunks into decoded NDJSON lines.
  #
  # Ollama's chat API is the one API that streams NDJSON.

  @doc """
  Transforms an enumerable of binary chunks into a stream of decoded JSON maps.

  Takes any enumerable of binaries, typically a `Req.Response.Async`, and
  yields one map per line. Empty lines, and lines that fail to decode, are
  skipped.
  """
  @spec stream(Enumerable.t()) :: Enumerable.t()
  def stream(async_body) do
    Stream.transform(
      async_body,
      fn -> "" end,
      &process_chunk/2,
      fn buffer ->
        case flush_buffer(buffer) do
          nil -> {[], ""}
          decoded -> {[decoded], ""}
        end
      end,
      fn _acc -> :ok end
    )
  end

  defp process_chunk(chunk, buffer) do
    extract_lines(buffer <> chunk, [])
  end

  defp extract_lines(data, acc) do
    case :binary.split(data, "\n") do
      [^data] ->
        {Enum.reverse(acc), data}

      [line, rest] ->
        case decode_line(line) do
          nil -> extract_lines(rest, acc)
          decoded -> extract_lines(rest, [decoded | acc])
        end
    end
  end

  defp flush_buffer(""), do: nil
  defp flush_buffer(buffer), do: decode_line(buffer)

  defp decode_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case JSON.decode(trimmed) do
        {:ok, map} -> map
        {:error, _} -> nil
      end
    end
  end
end
