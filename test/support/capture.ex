defmodule Omni.Test.Capture do
  @moduledoc false

  # Records real API responses as fixture files, and replays them. Capture
  # scripts (`test/support/fixtures/<provider>/capture.exs`) call `record/4`
  # once per fixture; tests call `replay/4`. A context records a text
  # response (`.sse` or `.ndjson`), a decision a decision response (`.json`).

  alias Omni.{Context, Decision, Model, Request, Response}

  # Options `Omni.Loop` takes before building a request.
  @loop_opts [:raw, :max_steps, :tool_timeout]

  @doc """
  Records one live response to `file`, unless it exists, then replays it.

  A missing file is recorded from one request built with `Request.build/3`
  (for a context, the request the loop sends on each step), and its raw bytes
  written. A failed
  request writes nothing, prints the error and returns it, so dependent steps
  chained with `with` are skipped and the script carries on. Re-recording
  means deleting the file first.

  `:pause` (milliseconds) waits before a live request, for providers with
  tight rate limits; replays don't wait.

      {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-5-5")
      Capture.record(model, Omni.context("Say hello"), "test/support/fixtures/anthropic/text.sse")
  """
  @spec record(Model.t(), Context.t() | Decision.t(), String.t(), keyword()) ::
          {:ok, Response.t() | Decision.t()} | {:error, term()}
  def record(%Model{} = model, input, file, opts \\ [])
      when is_struct(input, Context) or is_struct(input, Decision) do
    {pause, opts} = Keyword.pop(opts, :pause, 0)

    if File.exists?(file) do
      IO.puts("skipped  #{file}")
      replay(model, input, file, opts)
    else
      Process.sleep(pause)

      case fetch(model, input, opts) do
        {:ok, data} ->
          File.mkdir_p!(Path.dirname(file))
          File.write!(file, data)
          IO.puts("recorded #{file}")
          replay(model, input, file, opts)

        {:error, reason} = error ->
          IO.puts("failed   #{file}\n  #{inspect(reason, pretty: true)}")
          error
      end
    end
  end

  @doc """
  Replays `file` as the response to one request: through `Omni.generate_text/3`
  for a context, `Omni.decide/3` for a decision.

  Sends `{:replay_request, %{host: _, path: _, headers: _, body: _}}` to the
  caller for each request made, with the body JSON-decoded. Serves `.ndjson`
  files as NDJSON, `.json` as JSON and everything else as SSE.
  """
  @spec replay(Model.t(), Context.t() | Decision.t(), String.t(), keyword()) ::
          {:ok, Response.t() | Decision.t()} | {:error, term()}
  def replay(model, input, file, opts \\ [])

  def replay(%Model{} = model, %Context{} = context, file, opts) do
    opts = Keyword.merge(opts, api_key: "test-key", max_steps: 1, plug: plug(file))
    Omni.generate_text(model, context, opts)
  end

  def replay(%Model{} = model, %Decision{} = decision, file, opts) do
    opts = Keyword.merge(opts, api_key: "test-key", plug: plug(file))
    Omni.decide(model, decision, opts)
  end

  defp plug(file) do
    caller = self()

    content_type =
      case Path.extname(file) do
        ".ndjson" -> "application/x-ndjson"
        ".json" -> "application/json"
        _ -> "text/event-stream"
      end

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(caller, {
        :replay_request,
        %{
          host: conn.host,
          path: conn.request_path,
          headers: conn.req_headers,
          body: JSON.decode!(body)
        }
      })

      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, File.read!(file))
    end
  end

  # The raw bytes, as the API sent them: Req would decode a JSON body.
  defp fetch(model, %Decision{} = decision, opts) do
    with {:ok, req} <- Request.build(model, decision, opts),
         {:ok, resp} <- Req.request(req, decode_body: false) do
      case resp.status do
        200 -> {:ok, resp.body}
        status -> {:error, {:http_error, status, resp.body}}
      end
    end
  end

  defp fetch(model, context, opts) do
    with {:ok, req} <- Request.build(model, context, Keyword.drop(opts, @loop_opts)),
         {:ok, resp} <- Req.request(req) do
      data = resp.body |> Enum.to_list() |> IO.iodata_to_binary()

      case resp.status do
        200 -> {:ok, data}
        status -> {:error, {:http_error, status, data}}
      end
    end
  end
end
