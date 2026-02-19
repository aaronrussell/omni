defmodule Omni.Providers.OpenAILiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.Provider
  alias Omni.Providers.OpenAI
  alias Omni.SSE

  test "streams a real response from the OpenAI API" do
    body = %{
      "model" => "gpt-4.1-nano",
      "max_completion_tokens" => 50,
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "messages" => [%{"role" => "user", "content" => "Say hello in one word."}]
    }

    {:ok, req} = Provider.new_request(OpenAI, "/v1/chat/completions", body)
    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    events = resp.body |> SSE.stream() |> Enum.to_list()

    assert length(events) > 0

    # OpenAI chunks have choices arrays
    assert Enum.any?(events, &match?(%{"choices" => [_ | _]}, &1))
  end
end
