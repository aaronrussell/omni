defmodule Omni.Test.Capture do
  @moduledoc false

  @doc """
  Records a real streaming API response as an SSE fixture file.

  Builds a request via `Provider.new_request/4`, executes it, collects
  all async body chunks, and writes the raw SSE bytes to `output_path`.
  Uses real authentication from environment variables.

  ## Example

      Omni.Test.Capture.record(
        Omni.Providers.Anthropic,
        "/v1/messages",
        %{
          "model" => "claude-sonnet-4-20250514",
          "max_tokens" => 50,
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Say hello"}]
        },
        "test/support/fixtures/sse/anthropic_text.sse"
      )
  """
  @spec record(module(), String.t(), map(), String.t(), keyword()) :: :ok
  def record(provider, path, body, output_path, opts \\ []) do
    {:ok, req} = Omni.Provider.new_request(provider, path, body, opts)
    {:ok, resp} = Req.request(req)

    chunks =
      resp.body
      |> Enum.to_list()

    data = IO.iodata_to_binary(chunks)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, data)
    :ok
  end
end
