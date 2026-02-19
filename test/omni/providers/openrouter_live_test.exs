defmodule Omni.Providers.OpenRouterLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.Provider
  alias Omni.Providers.OpenRouter
  alias Omni.SSE

  setup do
    Provider.load([:openrouter])
    :ok
  end

  test "streams a real response from the OpenRouter API" do
    body = %{
      "model" => "meta-llama/llama-3.1-8b-instruct",
      "max_completion_tokens" => 50,
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "messages" => [%{"role" => "user", "content" => "Say hello in one word."}]
    }

    {:ok, req} = Provider.new_request(OpenRouter, "/v1/chat/completions", body)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    events = resp.body |> SSE.stream() |> Enum.to_list()

    assert length(events) > 0

    # OpenRouter uses OpenAI format — chunks have choices arrays
    assert Enum.any?(events, &match?(%{"choices" => [_ | _]}, &1))
  end
end
