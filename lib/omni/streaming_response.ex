defmodule Omni.StreamingResponse do
  @moduledoc """
  A streaming LLM response that yields events as they arrive from the provider.

  Returned by `Omni.stream_text/3`. The three most common consumption patterns:

  ## Stream to UI and get the final response

      {:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

      {:ok, response} =
        stream
        |> StreamingResponse.on(:text_delta, fn %{delta: d} -> IO.write(d) end)
        |> StreamingResponse.complete()

  ## Just the text chunks

      {:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

      stream
      |> StreamingResponse.text_stream()
      |> Enum.each(&IO.write/1)

  ## Full event control

  `StreamingResponse` implements `Enumerable`, yielding `{event_type, event_map,
  partial_response}` tuples. The partial response is rebuilt after every event to
  reflect the current state of the stream:

      {:ok, stream} = Omni.stream_text({:anthropic, "claude-sonnet-4-5-20250514"}, "Hello!")

      for {type, data, _partial} <- stream do
        case type do
          :text_delta -> IO.write(data.delta)
          :tool_use_start -> IO.puts("Calling tool: \#{data.name}")
          :done -> IO.puts("\\nDone! Stop reason: \#{data.stop_reason}")
          _ -> :ok
        end
      end

  ## Event types

  Content block lifecycle events follow a `start` → `delta` → `end` pattern:

      {:text_start,     %{index: 0}, %Response{}}
      {:text_delta,     %{index: 0, delta: "Hello"}, %Response{}}
      {:text_end,       %{index: 0, content: %Text{}}, %Response{}}

      {:thinking_start, %{index: 0}, %Response{}}
      {:thinking_delta, %{index: 0, delta: "..."}, %Response{}}
      {:thinking_end,   %{index: 0, content: %Thinking{}}, %Response{}}

      {:tool_use_start, %{index: 1, id: "call_1", name: "weather"}, %Response{}}
      {:tool_use_delta, %{index: 1, delta: "{\\"city\\":"}, %Response{}}
      {:tool_use_end,   %{index: 1, content: %ToolUse{}}, %Response{}}

  Tool results are emitted between rounds when tools are auto-executed. The
  third element is the completed response from the step that triggered tool
  execution (not a partial response):

      {:tool_result, %ToolResult{}, %Response{}}

  Terminal events — every stream ends with exactly one of these:

      {:done,  %{stop_reason: :stop}, %Response{}}
      {:error, reason, %Response{}}
  """

  alias Omni.{Message, Model, Response, Usage}
  alias Omni.Content.{Text, Thinking, ToolUse}

  import Omni.Util, only: [maybe_put: 3]

  defstruct [:stream, :cancel]

  @typedoc "A streaming response wrapper."
  @type t :: %__MODULE__{
          stream: Enumerable.t(),
          cancel: (-> :ok) | nil
        }

  @typedoc "An event type atom emitted during enumeration."
  @type event_type ::
          :text_start
          | :text_delta
          | :text_end
          | :thinking_start
          | :thinking_delta
          | :thinking_end
          | :tool_use_start
          | :tool_use_delta
          | :tool_use_end
          | :tool_result
          | :error
          | :done

  @typedoc "A consumer event emitted during enumeration."
  @type event :: {event_type(), map(), Response.t()} | {:error, term(), Response.t()}

  @doc false
  @spec new(Enumerable.t(), keyword()) :: t()
  def new(deltas, opts \\ []) do
    model = opts[:model]
    raw = opts[:raw]

    stream =
      Stream.transform(
        deltas,
        fn -> initial_acc(model, raw) end,
        &process_delta/2,
        &finalize/1,
        fn _acc -> :ok end
      )

    %__MODULE__{stream: stream, cancel: opts[:cancel]}
  end

  @doc """
  Consumes the entire stream and returns the final `%Response{}`.

  This drives the stream to completion, triggering any handlers registered
  with `on/3` along the way. Returns `{:ok, response}` on success or
  `{:error, reason}` if the stream terminated with an error.
  """
  @spec complete(t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%__MODULE__{} = sr) do
    case Enum.at(sr, -1) do
      {:done, _, response} -> {:ok, response}
      {:error, reason, _} -> {:error, reason}
      {_, _, %{error: reason}} when reason != nil -> {:error, reason}
      nil -> {:error, :empty_stream}
    end
  end

  @doc "Cancels the underlying async HTTP response."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{cancel: nil}), do: :ok
  def cancel(%__MODULE__{cancel: fun}), do: fun.()

  @doc """
  Registers a side-effect handler for events of the given type.

  Returns a new `StreamingResponse` with the handler inserted into the pipeline.
  Handlers fire during consumption (when `complete/1` or any `Enum` function
  drives the stream) and their return values are discarded.

  Multiple handlers can be chained — all fire independently:

      {:ok, response} =
        stream
        |> StreamingResponse.on(:text_delta, fn %{delta: d} -> IO.write(d) end)
        |> StreamingResponse.on(:thinking_delta, fn %{delta: d} -> IO.write(d) end)
        |> StreamingResponse.on(:done, fn %{stop_reason: r} -> IO.puts("\\nStop: \#{r}") end)
        |> StreamingResponse.complete()

  Use an arity-2 callback to access the partial response (e.g. for progress
  tracking based on accumulated token usage):

      StreamingResponse.on(stream, :text_delta, fn _event, partial ->
        send(self(), {:tokens, partial.usage.output_tokens})
      end)
  """
  @spec on(t(), event_type(), (map() -> any()) | (map(), Response.t() -> any())) :: t()
  def on(%__MODULE__{} = sr, event_type, callback)
      when is_atom(event_type) and is_function(callback, 1) do
    wrapped =
      Stream.each(sr.stream, fn
        {^event_type, event, _partial} -> callback.(event)
        _ -> :ok
      end)

    %__MODULE__{sr | stream: wrapped}
  end

  def on(%__MODULE__{} = sr, event_type, callback)
      when is_atom(event_type) and is_function(callback, 2) do
    wrapped =
      Stream.each(sr.stream, fn
        {^event_type, event, partial} -> callback.(event, partial)
        _ -> :ok
      end)

    %__MODULE__{sr | stream: wrapped}
  end

  @doc """
  Returns a stream of text delta binaries.

  Filters the event stream to only `:text_delta` events and extracts the
  delta string from each. Useful when you only need the text content:

      stream
      |> StreamingResponse.text_stream()
      |> Enum.into("")
  """
  @spec text_stream(t()) :: Enumerable.t()
  def text_stream(%__MODULE__{} = sr) do
    sr
    |> Stream.filter(fn {type, _, _} -> type == :text_delta end)
    |> Stream.map(fn {_, %{delta: delta}, _} -> delta end)
  end

  # -- Accumulator --

  defp initial_acc(model, raw) do
    %{
      blocks: %{},
      block_order: [],
      model_id: nil,
      stop_reason: nil,
      usage: %{},
      private: %{},
      error: nil,
      model: model,
      raw: raw
    }
  end

  # -- Delta Processing --

  defp process_delta({:message, data}, acc) do
    acc =
      acc
      |> maybe_put(:model_id, data[:model])
      |> maybe_put(:stop_reason, data[:stop_reason])
      |> merge_map(:usage, data[:usage])
      |> merge_private(data[:private])

    {[], acc}
  end

  defp process_delta({:block_start, data}, acc) do
    type = data.type
    index = data.index
    key = {type, index}

    block_acc = new_block_acc(type, data)
    acc = register_block(acc, key, block_acc)

    event_data = start_event_data(type, data)
    event = {start_atom(type), event_data, build_response(acc)}
    {[event], acc}
  end

  defp process_delta({:block_delta, data}, acc) do
    type = data.type
    index = data.index
    key = {type, index}

    {synth_events, acc} = maybe_synthesize_start(acc, key, type, index)

    acc = update_block(acc, key, data)

    delta_events =
      if data[:delta] do
        event_data = %{index: index, delta: data.delta}
        [{delta_atom(type), event_data, build_response(acc)}]
      else
        []
      end

    {synth_events ++ delta_events, acc}
  end

  defp process_delta({:error, reason}, acc) do
    error = {:stream_error, reason}
    acc = %{acc | error: error}
    event = {:error, error, build_response(acc)}
    {[event], acc}
  end

  # -- Finalization --

  defp finalize(acc) do
    ends = finalize_blocks(acc)

    if acc.error do
      {ends, acc}
    else
      {ends ++ [finalize_done(acc)], acc}
    end
  end

  defp finalize_blocks(acc) do
    Enum.map(acc.block_order, fn key ->
      block = Map.fetch!(acc.blocks, key)
      content = build_block(block)
      {type, index} = key
      {end_atom(type), %{index: index, content: content}, build_response(acc)}
    end)
  end

  defp finalize_done(acc) do
    stop_reason = infer_stop_reason(acc)
    acc = %{acc | stop_reason: stop_reason}
    response = build_response(acc)
    response = %{response | messages: [response.message]}
    response = if acc.raw, do: %{response | raw: [acc.raw]}, else: response
    {:done, %{stop_reason: stop_reason}, response}
  end

  # Google sends finishReason "STOP" even for function calls, and may split
  # the function call and finish reason across separate SSE events. Since
  # parse_event is stateless, the dialect can't detect this. We infer the
  # correct stop_reason from accumulated blocks at finalization.
  defp infer_stop_reason(%{stop_reason: reason, block_order: blocks}) do
    has_tool_use? = Enum.any?(blocks, fn {type, _} -> type == :tool_use end)

    cond do
      reason == :tool_use -> :tool_use
      has_tool_use? -> :tool_use
      true -> reason || :stop
    end
  end

  # -- Block Helpers --

  defp new_block_acc(:text, data) do
    %{type: :text, parts: [], signature: data[:signature]}
  end

  defp new_block_acc(:thinking, data) do
    %{
      type: :thinking,
      parts: [],
      signature: data[:signature],
      redacted_data: data[:redacted_data]
    }
  end

  defp new_block_acc(:tool_use, data) do
    %{
      type: :tool_use,
      id: data.id,
      name: data.name,
      parts: [],
      input: data[:input],
      signature: data[:signature]
    }
  end

  defp register_block(acc, key, block_acc) do
    %{
      acc
      | blocks: Map.put(acc.blocks, key, block_acc),
        block_order: acc.block_order ++ [key]
    }
  end

  defp update_block(acc, key, data) do
    block = Map.fetch!(acc.blocks, key)

    block =
      if data[:delta] do
        %{block | parts: [data.delta | block.parts]}
      else
        block
      end

    block =
      if data[:signature] do
        %{block | signature: data.signature}
      else
        block
      end

    %{acc | blocks: Map.put(acc.blocks, key, block)}
  end

  defp maybe_synthesize_start(acc, key, type, index) when type in [:text, :thinking] do
    if Map.has_key?(acc.blocks, key) do
      {[], acc}
    else
      block_acc = %{type: type, parts: [], signature: nil}

      block_acc =
        if type == :thinking, do: Map.put(block_acc, :redacted_data, nil), else: block_acc

      acc = register_block(acc, key, block_acc)
      event = {start_atom(type), %{index: index}, build_response(acc)}
      {[event], acc}
    end
  end

  defp maybe_synthesize_start(acc, _key, _type, _index) do
    {[], acc}
  end

  defp start_event_data(:tool_use, data) do
    map = %{index: data.index, id: data.id, name: data.name}
    if data[:input], do: Map.put(map, :input, data.input), else: map
  end

  defp start_event_data(_type, data) do
    %{index: data.index}
  end

  # -- Block Finalization --

  defp build_block(%{type: :text} = b) do
    text = b.parts |> Enum.reverse() |> IO.iodata_to_binary()
    Text.new(text: text, signature: b.signature)
  end

  defp build_block(%{type: :thinking, redacted_data: rd} = b) when not is_nil(rd) do
    Thinking.new(redacted_data: rd, signature: b.signature)
  end

  defp build_block(%{type: :thinking} = b) do
    text = b.parts |> Enum.reverse() |> IO.iodata_to_binary()
    Thinking.new(text: text, signature: b.signature)
  end

  defp build_block(%{type: :tool_use} = b) do
    input =
      if b.input do
        b.input
      else
        json = b.parts |> Enum.reverse() |> IO.iodata_to_binary()

        case JSON.decode(json) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end
      end

    ToolUse.new(id: b.id, name: b.name, input: input, signature: b.signature)
  end

  # -- Response Building --

  defp build_response(acc) do
    content =
      Enum.map(acc.block_order, fn key ->
        acc.blocks |> Map.fetch!(key) |> build_block()
      end)

    message = Message.new(role: :assistant, content: content, private: acc.private)
    usage = build_usage(acc.usage, acc.model)

    Response.new(
      message: message,
      model: acc.model,
      usage: usage,
      stop_reason: acc.stop_reason,
      error: acc.error
    )
  end

  # -- Usage --

  defp build_usage(raw, nil), do: build_usage(raw, %{})

  defp build_usage(raw, %Model{} = model) do
    pricing = %{
      input_cost: model.input_cost,
      output_cost: model.output_cost,
      cache_read_cost: model.cache_read_cost,
      cache_write_cost: model.cache_write_cost
    }

    build_usage(raw, pricing)
  end

  defp build_usage(raw, pricing) do
    input = raw["input_tokens"] || 0
    output = raw["output_tokens"] || 0
    cache_read = raw["cache_read_input_tokens"] || 0
    cache_write = raw["cache_creation_input_tokens"] || 0

    input_cost = input * (pricing[:input_cost] || 0) / 1_000_000
    output_cost = output * (pricing[:output_cost] || 0) / 1_000_000
    cache_read_cost = cache_read * (pricing[:cache_read_cost] || 0) / 1_000_000
    cache_write_cost = cache_write * (pricing[:cache_write_cost] || 0) / 1_000_000

    Usage.new(
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      total_tokens: input + output + cache_read + cache_write,
      input_cost: input_cost,
      output_cost: output_cost,
      cache_read_cost: cache_read_cost,
      cache_write_cost: cache_write_cost,
      total_cost: input_cost + output_cost + cache_read_cost + cache_write_cost
    )
  end

  # -- Atom Helpers --

  defp start_atom(:text), do: :text_start
  defp start_atom(:thinking), do: :thinking_start
  defp start_atom(:tool_use), do: :tool_use_start

  defp delta_atom(:text), do: :text_delta
  defp delta_atom(:thinking), do: :thinking_delta
  defp delta_atom(:tool_use), do: :tool_use_delta

  defp end_atom(:text), do: :text_end
  defp end_atom(:thinking), do: :thinking_end
  defp end_atom(:tool_use), do: :tool_use_end

  # -- Map Helpers --

  defp merge_private(acc, nil), do: acc

  defp merge_private(acc, private) do
    Map.update!(acc, :private, fn existing ->
      Map.merge(existing, private, fn
        _key, v1, v2 when is_list(v1) and is_list(v2) -> v1 ++ v2
        _key, _v1, v2 -> v2
      end)
    end)
  end

  defp merge_map(acc, _key, nil), do: acc
  defp merge_map(acc, key, map), do: Map.update!(acc, key, &Map.merge(&1, map))

  # -- Enumerable --

  defimpl Enumerable do
    def reduce(sr, cmd, fun) do
      Enumerable.reduce(sr.stream, cmd, fun)
    end

    def count(_sr), do: {:error, __MODULE__}
    def member?(_sr, _val), do: {:error, __MODULE__}
    def slice(_sr), do: {:error, __MODULE__}
  end
end
