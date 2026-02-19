defmodule Omni.Dialects.AnthropicMessagesLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Provider, SSE}
  alias Omni.Providers.Anthropic

  test "full pipeline with live Anthropic API" do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
    context = Context.new("Say hello in one word.")

    {:ok, req} = Provider.build_request(model, context, max_tokens: 50)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.flat_map(&Provider.parse_event(Anthropic, &1))
      |> Enum.to_list()

    types = Enum.map(deltas, &elem(&1, 0))

    assert :message in types
    assert :block_start in types
    assert :block_delta in types
  end
end
