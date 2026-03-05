defmodule Omni.Agent.Step do
  @moduledoc false

  alias Omni.Response

  @doc """
  Starts a linked step process that streams an LLM request.

  The step process sends ref-tagged messages back to the parent:

    - `{ref, {:event, type, event_map}}` — streaming events to forward
    - `{ref, {:complete, %Response{}}}` — successful completion
    - `{ref, {:error, reason}}` — failure

  Uses `Task.start_link/1` so `$callers` is propagated automatically,
  allowing process-ownership registries (Req.Test, Mox) to work.
  """
  def start_link(parent, ref, model, context, opts) do
    Task.start_link(fn -> run(parent, ref, model, context, opts) end)
  end

  defp run(parent, ref, model, context, opts) do
    try do
      case Omni.stream_text(model, context, opts) do
        {:ok, sr} ->
          response =
            Enum.reduce(sr, nil, fn
              {:done, _map, response}, _acc ->
                response

              {:error, reason, _response}, _acc ->
                throw({:stream_error, reason})

              {type, event_map, _partial_response}, _acc ->
                send(parent, {ref, {:event, type, event_map}})
                nil
            end)

          case response do
            %Response{} -> send(parent, {ref, {:complete, response}})
            nil -> send(parent, {ref, {:error, :no_response}})
          end

        {:error, reason} ->
          send(parent, {ref, {:error, reason}})
      end
    rescue
      e -> send(parent, {ref, {:error, e}})
    catch
      {:stream_error, reason} ->
        send(parent, {ref, {:error, reason}})
    end
  end
end
