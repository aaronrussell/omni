defmodule Omni.Dialects.OpenAIResponsesLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Provider, SSE}
  alias Omni.Providers.OpenAI

  test "full pipeline with live OpenAI Responses API" do
    {:ok, model} = Omni.get_model(:openai, "gpt-4.1-nano")
    context = Context.new("Say hello in one word.")

    {:ok, req} = Provider.build_request(model, context, max_tokens: 50)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.map(&Provider.parse_event(OpenAI, &1))
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

    types = Enum.map(deltas, &elem(&1, 0))

    assert :start in types
    assert :text_delta in types
    assert :done in types
  end
end
