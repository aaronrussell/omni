defmodule Omni.Test.Capture do
  @moduledoc false

  alias Omni.{Context, Model, Provider}

  @doc """
  Records a real streaming API response as an SSE fixture file.

  Uses `Provider.build_request/3` to build the request from Omni types,
  executes it, collects all async body chunks, and writes the raw SSE
  bytes to `output_path`.

  ## Example

      {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
      context = Omni.context("Say hello")

      Omni.Test.Capture.record(model, context, "test/support/fixtures/sse/anthropic_text.sse")
  """
  @spec record(Model.t(), Context.t(), String.t(), keyword()) :: :ok
  def record(%Model{} = model, %Context{} = context, output_path, opts \\ []) do
    {:ok, req} = Provider.build_request(model, context, opts)
    {:ok, resp} = Req.request(req)

    data =
      resp.body
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, data)
    :ok
  end
end
