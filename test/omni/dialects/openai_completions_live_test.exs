defmodule Omni.Dialects.OpenAICompletionsLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.{Context, Provider, SSE}
  alias Omni.Providers.OpenRouter

  setup_all do
    Provider.load([:openrouter])
    :ok
  end

  test "full pipeline with live OpenRouter API" do
    {:ok, model} = Omni.get_model(:openrouter, "openai/gpt-4.1-mini")
    context = Context.new("Say hello in one word.")

    {:ok, req} = Provider.build_request(model, context, max_tokens: 50)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    deltas =
      resp.body
      |> SSE.stream()
      |> Stream.flat_map(&Provider.parse_event(OpenRouter, &1))
      |> Enum.to_list()

    types = Enum.map(deltas, &elem(&1, 0))

    assert :message in types
    assert :block_delta in types
  end
end
