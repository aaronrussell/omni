defmodule Omni.StreamingResponseTest do
  use ExUnit.Case, async: true

  alias Omni.StreamingResponse
  alias Omni.{Context, Model, Provider, Response}
  alias Omni.Content.{Text, Thinking, ToolUse}
  alias Omni.Providers.{Anthropic, Google}
  alias Omni.Dialects.{AnthropicMessages, GoogleGemini}

  @fixtures "test/support/fixtures/sse"

  # -- Test Models --

  @anthropic_model Model.new(
                     id: "claude-haiku-4-5-20251001",
                     name: "Claude Haiku",
                     provider: Anthropic,
                     dialect: AnthropicMessages,
                     max_output_tokens: 8192,
                     input_cost: 0.80,
                     output_cost: 4.0,
                     cache_read_cost: 0.08,
                     cache_write_cost: 1.0
                   )

  @anthropic_reasoning_model Model.new(
                               id: "claude-sonnet-4-20250514",
                               name: "Claude Sonnet 4",
                               provider: Anthropic,
                               dialect: AnthropicMessages,
                               max_output_tokens: 16384,
                               reasoning: true
                             )

  @google_model Model.new(
                  id: "gemini-2.0-flash-lite",
                  name: "Gemini 2.0 Flash Lite",
                  provider: Google,
                  dialect: GoogleGemini,
                  max_output_tokens: 8192
                )

  # -- Helpers --

  defp stub_fixture(name, fixture_file) do
    Req.Test.stub(name, fn conn ->
      body = File.read!(Path.join(@fixtures, fixture_file))

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp start_with_fixture(model, stub_name) do
    context = Context.new("Hello")
    {:ok, req} = Provider.build_request(model, context, api_key: "test-key")
    req = Req.merge(req, plug: {Req.Test, stub_name})
    StreamingResponse.start(req, model)
  end

  defp event_types(consumer_events) do
    Enum.map(consumer_events, fn {type, _data, _resp} -> type end)
  end

  defp collect_scripted(events, opts \\ []) do
    sr = StreamingResponse.new(events: events, model: opts[:model])
    Enum.to_list(sr)
  end

  # ============================================================
  # Integration tests — real fixtures through start/2
  # ============================================================

  describe "Anthropic text streaming" do
    setup do
      stub_fixture(:sr_anthropic_text, "anthropic_text.sse")
      :ok
    end

    test "start/2 → enumerate yields text lifecycle events" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      events = Enum.to_list(sr)
      types = event_types(events)

      assert :text_start in types
      assert :text_delta in types
      assert :text_end in types
      assert :done in types
      assert List.last(types) == :done
    end

    test "text_end carries complete Text content" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      events = Enum.to_list(sr)
      {_, %{content: content}, _} = Enum.find(events, &match?({:text_end, _, _}, &1))

      assert %Text{text: text} = content
      assert is_binary(text) and text != ""
    end

    test "done carries stop_reason" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      events = Enum.to_list(sr)
      {:done, %{stop_reason: stop_reason}, _} = List.last(events)

      assert stop_reason == :stop
    end

    test "complete/1 returns final response" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      assert {:ok, %Response{} = resp} = StreamingResponse.complete(sr)
      assert resp.stop_reason == :stop
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
    end

    test "complete/1 sets raw to {req, resp}" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      assert {:ok, %Response{raw: {%Req.Request{}, %Req.Response{}}}} =
               StreamingResponse.complete(sr)
    end

    test "text_stream/1 yields text binaries" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)

      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &is_binary/1)
      assert Enum.join(texts) != ""
    end

    test "usage includes costs from model pricing" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_text)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.usage.input_cost == resp.usage.input_tokens * @anthropic_model.input_cost
      assert resp.usage.output_cost == resp.usage.output_tokens * @anthropic_model.output_cost
      assert resp.usage.total_cost > 0
    end
  end

  describe "Anthropic tool use streaming" do
    setup do
      stub_fixture(:sr_anthropic_tool_use, "anthropic_tool_use.sse")
      :ok
    end

    test "yields text and tool_use lifecycle events" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_tool_use)

      events = Enum.to_list(sr)
      types = event_types(events)

      assert :text_start in types
      assert :tool_use_start in types
      assert :tool_use_delta in types
      assert :tool_use_end in types
    end

    test "tool_use_start carries id and name" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_tool_use)

      events = Enum.to_list(sr)
      {_, data, _} = Enum.find(events, &match?({:tool_use_start, _, _}, &1))

      assert is_binary(data.id) and data.id != ""
      assert is_binary(data.name) and data.name != ""
    end

    test "tool_use_end carries ToolUse with parsed input" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_tool_use)

      events = Enum.to_list(sr)
      {_, %{content: content}, _} = Enum.find(events, &match?({:tool_use_end, _, _}, &1))

      assert %ToolUse{id: id, name: name, input: input} = content
      assert is_binary(id) and id != ""
      assert is_binary(name) and name != ""
      assert is_map(input) and map_size(input) > 0
    end

    test "complete/1 returns response with text and tool_use blocks" do
      {:ok, sr} = start_with_fixture(@anthropic_model, :sr_anthropic_tool_use)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.stop_reason == :tool_use

      assert Enum.any?(resp.message.content, &match?(%Text{}, &1))
      assert Enum.any?(resp.message.content, &match?(%ToolUse{}, &1))
    end
  end

  describe "Anthropic thinking streaming" do
    setup do
      stub_fixture(:sr_anthropic_thinking, "anthropic_thinking.sse")
      :ok
    end

    test "yields thinking and text lifecycle events" do
      {:ok, sr} = start_with_fixture(@anthropic_reasoning_model, :sr_anthropic_thinking)

      events = Enum.to_list(sr)
      types = event_types(events)

      assert :thinking_start in types
      assert :thinking_delta in types
      assert :thinking_end in types
      assert :text_start in types
      assert :text_delta in types
      assert :text_end in types
    end

    test "thinking_end carries Thinking with text and signature" do
      {:ok, sr} = start_with_fixture(@anthropic_reasoning_model, :sr_anthropic_thinking)

      events = Enum.to_list(sr)
      {_, %{content: content}, _} = Enum.find(events, &match?({:thinking_end, _, _}, &1))

      assert %Thinking{text: text, signature: sig} = content
      assert is_binary(text) and text != ""
      assert is_binary(sig) and sig != ""
    end

    test "complete/1 returns response with thinking and text" do
      {:ok, sr} = start_with_fixture(@anthropic_reasoning_model, :sr_anthropic_thinking)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert Enum.any?(resp.message.content, &match?(%Thinking{}, &1))
      assert Enum.any?(resp.message.content, &match?(%Text{}, &1))
    end
  end

  describe "Google text streaming" do
    setup do
      stub_fixture(:sr_google_text, "google_text.sse")
      :ok
    end

    test "start/2 → complete/1 works with Google dialect" do
      {:ok, sr} = start_with_fixture(@google_model, :sr_google_text)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.stop_reason == :stop
      assert [%Text{text: text}] = resp.message.content
      assert is_binary(text) and text != ""
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
    end

    test "text_stream/1 yields text fragments" do
      {:ok, sr} = start_with_fixture(@google_model, :sr_google_text)
      texts = sr |> StreamingResponse.text_stream() |> Enum.to_list()

      assert length(texts) > 0
      assert Enum.all?(texts, &(is_binary(&1) and &1 != ""))
    end
  end

  # ============================================================
  # Unit tests — scripted deltas through new/1
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
        {:error, %{reason: "rate_limit"}}
      ]

      result = collect_scripted(events)

      {_, _, resp} = Enum.find(result, &match?({:error, _, _}, &1))
      assert resp.error == "rate_limit"
    end

    test "complete/1 returns {:error, reason} on error" do
      events = [
        {:error, %{reason: "overloaded"}}
      ]

      sr = StreamingResponse.new(events: events)
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
    test "returns :ok with nil resp" do
      sr = StreamingResponse.new(events: [])
      assert :ok = StreamingResponse.cancel(sr)
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

      sr = StreamingResponse.new(events: events, model: model)
      {:ok, resp} = StreamingResponse.complete(sr)

      assert resp.usage.input_tokens == 100
      assert resp.usage.output_tokens == 50
      assert resp.usage.cache_read_tokens == 20
      assert resp.usage.cache_write_tokens == 10
      assert resp.usage.total_tokens == 180

      assert resp.usage.input_cost == 300.0
      assert resp.usage.output_cost == 750.0
      assert resp.usage.cache_read_cost == 6.0
      assert resp.usage.cache_write_cost == 37.5
      assert resp.usage.total_cost == 1093.5
    end

    test "nil model produces zero costs" do
      events = [
        {:message, %{usage: %{"input_tokens" => 100, "output_tokens" => 50}, stop_reason: :stop}},
        {:block_delta, %{type: :text, index: 0, delta: "Hi"}}
      ]

      sr = StreamingResponse.new(events: events, model: nil)
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
