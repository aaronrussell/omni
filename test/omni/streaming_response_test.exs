defmodule Omni.StreamingResponseTest do
  use ExUnit.Case, async: true

  alias Omni.StreamingResponse
  alias Omni.{Model, Response}
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Providers.Anthropic
  alias Omni.Dialects.AnthropicMessages

  # -- Helpers --

  defp event_types(consumer_events) do
    Enum.map(consumer_events, fn {type, _data, _resp} -> type end)
  end

  defp collect_scripted(events, opts \\ []) do
    sr = StreamingResponse.new(events, opts)
    Enum.to_list(sr)
  end

  # ============================================================
  # Integration tests — skipped pending Phase 5 (stream_text)
  # ============================================================

  # Integration tests that exercised start/2 with real SSE fixtures have been
  # removed. The same coverage will be provided by stream_text/generate_text
  # integration tests in Phase 5. Dialect-level parsing is already covered by
  # each dialect's own integration tests.

  # ============================================================
  # Unit tests — scripted deltas through new/2
  # ============================================================

  describe "implicit text start (synthesized)" do
    test "first block_delta synthesizes _start" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world"}}
      ]

      result = collect_scripted(events)
      types = event_types(result)

      assert types == [:text_start, :text_delta, :text_delta, :text_end, :done]

      {_, %{content: content}, _} = Enum.find(result, &match?({:text_end, _, _}, &1))
      assert %Text{text: "Hello world"} = content
    end
  end

  describe "Google tool use (complete input in block_start)" do
    test "carries input without needing deltas" do
      events = [
        {:block_start,
         %{type: :tool_use, index: 0, id: "call_g", name: "search", input: %{"q" => "elixir"}}}
      ]

      result = collect_scripted(events)
      types = event_types(result)

      assert types == [:tool_use_start, :tool_use_end, :done]

      {_, start_data, _} = Enum.find(result, &match?({:tool_use_start, _, _}, &1))
      assert start_data.input == %{"q" => "elixir"}

      {_, %{content: content}, _} = Enum.find(result, &match?({:tool_use_end, _, _}, &1))
      assert %ToolUse{input: %{"q" => "elixir"}, name: "search"} = content
    end
  end

  describe "redacted thinking" do
    test "block_start with redacted_data, text is nil" do
      events = [
        {:block_start, %{type: :thinking, index: 0, redacted_data: "encrypted_blob"}}
      ]

      result = collect_scripted(events)
      types = event_types(result)

      assert types == [:thinking_start, :thinking_end, :done]

      {_, %{content: content}, _} = Enum.find(result, &match?({:thinking_end, _, _}, &1))
      assert %Thinking{text: nil, redacted_data: "encrypted_blob"} = content
    end
  end

  describe "signatures" do
    test "signature on delta updates content block" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world", signature: "sig_abc"}}
      ]

      result = collect_scripted(events)
      {_, %{content: content}, _} = Enum.find(result, &match?({:text_end, _, _}, &1))
      assert %Text{text: "Hello world", signature: "sig_abc"} = content
    end

    test "signature-only delta skips consumer event" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, signature: "sig_xyz"}}
      ]

      result = collect_scripted(events)
      types = event_types(result)

      assert types == [:text_start, :text_delta, :text_end, :done]

      {_, %{content: content}, _} = Enum.find(result, &match?({:text_end, _, _}, &1))
      assert %Text{signature: "sig_xyz"} = content
    end
  end

  describe "private data" do
    test "accumulated on Message.private" do
      events = [
        {:message, %{private: %{reasoning_details: "some data"}}},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      result = collect_scripted(events)
      {:done, _, resp} = List.last(result)
      assert resp.message.private.reasoning_details == "some data"
    end

    test "list values in private are concatenated across multiple :message events" do
      events = [
        {:message,
         %{
           private: %{
             reasoning_details: [%{"type" => "reasoning.summary", "summary" => "thinking"}]
           }
         }},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}},
        {:message,
         %{private: %{reasoning_details: [%{"type" => "reasoning.encrypted", "data" => "blob"}]}}}
      ]

      result = collect_scripted(events)
      {:done, _, resp} = List.last(result)

      assert resp.message.private.reasoning_details == [
               %{"type" => "reasoning.summary", "summary" => "thinking"},
               %{"type" => "reasoning.encrypted", "data" => "blob"}
             ]
    end

    test "non-list private values still overwrite" do
      events = [
        {:message, %{private: %{some_key: "first"}}},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}},
        {:message, %{private: %{some_key: "second"}}}
      ]

      result = collect_scripted(events)
      {:done, _, resp} = List.last(result)
      assert resp.message.private.some_key == "second"
    end
  end

  describe "message merging" do
    test "multiple :message events are merged" do
      events = [
        {:message, %{model: "gpt-4"}},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}},
        {:message, %{stop_reason: :stop, usage: %{"input_tokens" => 10}}},
        {:message, %{usage: %{"output_tokens" => 5}}}
      ]

      result = collect_scripted(events)
      {:done, %{stop_reason: stop}, resp} = List.last(result)

      assert stop == :stop
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5
    end
  end

  describe "error handling" do
    test "error event emits :error and sets response.error" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "partial"}},
        {:error, "rate_limit"}
      ]

      result = collect_scripted(events)

      {_, _, resp} = Enum.find(result, &match?({:error, _, _}, &1))
      assert resp.error == "rate_limit"
    end

    test "error event is terminal — no :done follows" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "partial"}},
        {:error, "rate_limit"}
      ]

      result = collect_scripted(events)
      types = event_types(result)

      assert :error in types
      refute :done in types

      # Block _end events still fire (partial content finalized)
      assert :text_end in types
    end

    test "complete/1 returns {:error, reason} on error" do
      events = [
        {:error, "overloaded"}
      ]

      sr = StreamingResponse.new(events)
      assert {:error, "overloaded"} = StreamingResponse.complete(sr)
    end
  end

  describe "graceful JSON decode failure" do
    test "tool_use with invalid JSON falls back to empty map" do
      events = [
        {:block_start, %{type: :tool_use, index: 0, id: "c1", name: "broken"}},
        {:block_delta, %{type: :tool_use, index: 0, delta: "{invalid"}}
      ]

      result = collect_scripted(events)
      {_, %{content: content}, _} = Enum.find(result, &match?({:tool_use_end, _, _}, &1))
      assert %ToolUse{input: %{}} = content
    end
  end

  describe "cancel/1" do
    test "returns :ok with nil cancel function" do
      sr = StreamingResponse.new([])
      assert :ok = StreamingResponse.cancel(sr)
    end

    test "invokes the cancel function" do
      test_pid = self()

      cancel_fn = fn ->
        send(test_pid, :cancelled)
        :ok
      end

      sr = StreamingResponse.new([], cancel: cancel_fn)
      assert :ok = StreamingResponse.cancel(sr)
      assert_received :cancelled
    end
  end

  describe "complete/1" do
    test "returns final response on success" do
      events = [
        {:message, %{stop_reason: :stop}},
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
      ]

      sr = StreamingResponse.new(events)
      assert {:ok, %Response{} = resp} = StreamingResponse.complete(sr)
      assert resp.stop_reason == :stop
      assert [%Text{text: "Hello"}] = resp.message.content
    end

    test "attaches raw to final response when provided" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      fake_req = %Req.Request{}
      fake_resp = %Req.Response{status: 200, body: ""}

      sr = StreamingResponse.new(events, raw: {fake_req, fake_resp})

      assert {:ok, %Response{raw: [{%Req.Request{}, %Req.Response{}}]}} =
               StreamingResponse.complete(sr)
    end

    test "raw is nil when not provided" do
      events = [{:block_delta, %{type: :text, index: 0, delta: "Hi"}}]
      sr = StreamingResponse.new(events)
      assert {:ok, %Response{raw: nil}} = StreamingResponse.complete(sr)
    end
  end

  describe "text_stream/1" do
    test "yields only text delta binaries" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world"}}
      ]

      sr = StreamingResponse.new(events)
      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert texts == ["Hello", " world"]
    end
  end

  describe "on/3" do
    test "fires handler for matching event type" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:text_delta, fn %{delta: d} ->
          send(test_pid, {:chunk, d})
        end)
        |> StreamingResponse.complete()

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "does not fire for non-matching events" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:thinking_delta, fn %{delta: d} ->
          send(test_pid, {:thinking, d})
        end)
        |> StreamingResponse.complete()

      refute_received {:thinking, _}
    end

    test "multiple handlers for different event types" do
      events = [
        {:block_start, %{type: :tool_use, index: 0, id: "c1", name: "search"}},
        {:block_delta, %{type: :tool_use, index: 0, delta: ~s({"q":"elixir"})}},
        {:block_delta, %{type: :text, index: 1, delta: "Result"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:text_delta, fn %{delta: d} ->
          send(test_pid, {:text, d})
        end)
        |> StreamingResponse.on(:tool_use_start, fn %{name: n} ->
          send(test_pid, {:tool, n})
        end)
        |> StreamingResponse.complete()

      assert_received {:text, "Result"}
      assert_received {:tool, "search"}
    end

    test "multiple handlers for the same event type both fire" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:text_delta, fn _ -> send(test_pid, :first) end)
        |> StreamingResponse.on(:text_delta, fn _ -> send(test_pid, :second) end)
        |> StreamingResponse.complete()

      assert_received :first
      assert_received :second
    end

    test "arity-2 callback receives partial response" do
      events = [
        {:message, %{stop_reason: :stop}},
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:text_delta, fn _event, partial ->
          send(test_pid, {:partial, partial.message.content})
        end)
        |> StreamingResponse.complete()

      assert_received {:partial, [%Text{text: "Hello"}]}
      assert_received {:partial, [%Text{text: "Hello world"}]}
    end

    test "complete/1 still returns final response" do
      events = [
        {:message, %{stop_reason: :stop}},
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}}
      ]

      sr = StreamingResponse.new(events)

      {:ok, response} =
        sr
        |> StreamingResponse.on(:text_delta, fn _ -> :noop end)
        |> StreamingResponse.complete()

      assert %Response{} = response
      assert response.stop_reason == :stop
      assert [%Text{text: "Hello"}] = response.message.content
    end

    test "handler on :done fires at stream end" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:ok, _response} =
        sr
        |> StreamingResponse.on(:done, fn %{stop_reason: sr} ->
          send(test_pid, {:done, sr})
        end)
        |> StreamingResponse.complete()

      assert_received {:done, :stop}
    end

    test "handler on :error fires on stream error" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "partial"}},
        {:error, "rate_limit"}
      ]

      sr = StreamingResponse.new(events)
      test_pid = self()

      {:error, "rate_limit"} =
        sr
        |> StreamingResponse.on(:error, fn reason ->
          send(test_pid, {:error, reason})
        end)
        |> StreamingResponse.complete()

      assert_received {:error, "rate_limit"}
    end
  end

  describe "usage computation" do
    test "token counts with model pricing" do
      model =
        Model.new(
          id: "test",
          name: "Test",
          provider: Anthropic,
          dialect: AnthropicMessages,
          input_cost: 3.0,
          output_cost: 15.0,
          cache_read_cost: 0.3,
          cache_write_cost: 3.75
        )

      events = [
        {:message,
         %{
           usage: %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "cache_read_input_tokens" => 20,
             "cache_creation_input_tokens" => 10
           },
           stop_reason: :stop
         }},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      sr = StreamingResponse.new(events, model: model)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.usage.input_tokens == 100
      assert resp.usage.output_tokens == 50
      assert resp.usage.cache_read_tokens == 20
      assert resp.usage.cache_write_tokens == 10
      assert resp.usage.total_tokens == 180

      assert resp.usage.input_cost == 0.0003
      assert resp.usage.output_cost == 0.00075
      assert resp.usage.cache_read_cost == 0.000006
      assert resp.usage.cache_write_cost == 0.0000375
      assert_in_delta resp.usage.total_cost, 0.0010935, 1.0e-10
    end

    test "nil model produces zero costs" do
      events = [
        {:message, %{usage: %{"input_tokens" => 100, "output_tokens" => 50}, stop_reason: :stop}},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      sr = StreamingResponse.new(events, model: nil)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.usage.input_tokens == 100
      assert resp.usage.output_tokens == 50
      assert resp.usage.input_cost == 0
      assert resp.usage.output_cost == 0
    end
  end

  describe "partial response" do
    test "mid-stream events show in-progress content" do
      events = [
        {:block_delta, %{type: :text, index: 0, delta: "Hello"}},
        {:block_delta, %{type: :text, index: 0, delta: " world"}}
      ]

      result = collect_scripted(events)

      # First text_delta has partial "Hello"
      {_, _, resp1} = Enum.at(result, 1)
      assert [%Text{text: "Hello"}] = resp1.message.content

      # Second text_delta has accumulated "Hello world"
      {_, _, resp2} = Enum.at(result, 2)
      assert [%Text{text: "Hello world"}] = resp2.message.content
    end
  end
end
