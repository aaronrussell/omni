defmodule Omni.Providers.AnthropicIntegrationTest do
  use ExUnit.Case, async: true

  alias Omni.Provider
  alias Omni.Providers.Anthropic
  alias Omni.SSE

  @fixture_path "test/support/fixtures/sse/anthropic_text.sse"

  setup do
    Req.Test.stub(:anthropic, fn conn ->
      body = File.read!(@fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  test "new_request/4 → Req.request/1 → SSE.stream/1 pipeline" do
    {:ok, req} =
      Provider.new_request(Anthropic, "/v1/messages", %{"model" => "test", "stream" => true},
        api_key: "test-key"
      )

    {:ok, resp} = req |> Req.merge(plug: {Req.Test, :anthropic}) |> Req.request()

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    events = resp.body |> SSE.stream() |> Enum.to_list()

    assert length(events) > 0

    types = Enum.map(events, & &1["type"])

    assert "message_start" in types
    assert "content_block_delta" in types
    assert "message_delta" in types
  end

  test "text deltas contain expected content" do
    {:ok, req} =
      Provider.new_request(Anthropic, "/v1/messages", %{"model" => "test", "stream" => true},
        api_key: "test-key"
      )

    {:ok, resp} = req |> Req.merge(plug: {Req.Test, :anthropic}) |> Req.request()

    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.filter(&(&1["type"] == "content_block_delta"))
      |> Enum.map(& &1["delta"]["text"])
      |> Enum.filter(&is_binary/1)

    assert length(deltas) > 0
    assert Enum.all?(deltas, &(is_binary(&1) and &1 != ""))
    assert Enum.join(deltas) != ""
  end
end
