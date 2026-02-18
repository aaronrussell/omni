defmodule Omni.Providers.AnthropicLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.Provider
  alias Omni.Providers.Anthropic
  alias Omni.SSE

  test "streams a real response from the Anthropic API" do
    body = %{
      "model" => "claude-haiku-4-5",
      "max_tokens" => 50,
      "stream" => true,
      "messages" => [%{"role" => "user", "content" => "Say hello in one word."}]
    }

    {:ok, req} = Provider.new_request(Anthropic, "/v1/messages", body)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    events = resp.body |> SSE.stream() |> Enum.to_list()

    assert length(events) > 0

    types = Enum.map(events, & &1["type"])
    assert "message_start" in types
    assert "message_stop" in types
  end
end
